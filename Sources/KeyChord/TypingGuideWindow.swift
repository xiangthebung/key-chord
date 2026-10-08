// Typing Guide: a typeracer-style practice window. The passage is shown at the top, colored as you type
// into the box below it. Only the current word's chord combination is shown, and a keyboard diagram
// (the MacBook's US or Canadian French keyboard) shows the keys to press next and the keys actually held.
// The plan comes from TypingPlanner (KeyChordCore), which checks every step against the Chord_Engine.
// The text and what is typed stay in memory only; only aggregate practice performance is saved.

import AppKit
import KeyChordCore
import UniformTypeIdentifiers

/// A physical key going down or up, forwarded from the event tap before chord keys are held back.
enum RawKeyEvent {
    case down(KeyCode)
    case up(KeyCode)
}

final class TypingGuideWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate, NSPopoverDelegate, NSMenuItemValidation {
    /// Called when the window becomes or stops being the key window.
    var onFocus: ((Bool) -> Void)?
    /// Asks KeyChord to forget the text before the cursor (so the first chord gets no leading space).
    var onResetContext: (() -> Void)?
    /// Puts KeyChord's output context (spacing, pending capital) where the plan expects it. Used after the
    /// user fixes a mistake: Delete resets the context, so without this the next chord would lose its space
    /// or its capital.
    var onSyncContext: ((EngineContext) -> Void)?
    /// Keeps the router's sub-mode aligned with the selected practice mode.
    var onPracticeModeChanged: ((SubMode) -> Void)?
    /// Explicit Start/Pause, routed through the controller's existing availability checks.
    var onPracticeActiveChanged: ((Bool, SubMode) -> Void)?
    /// Opens the app-owned, voluntary editor exercise. Self-reported use never marks measured mastery.
    var onUseInEditor: (() -> Void)? { didSet { updateLearningStage() } }
    var onOpenReference: (() -> Void)?
    var onOpenKeyboardTools: (() -> Void)?
    var onEnableOtherApps: (() -> Void)? { didSet { enableOtherAppsButton.isEnabled = onEnableOtherApps != nil } }
    /// What the Matrix Scan found; blocked chords are never suggested. Takes effect on the next plan.
    var limits: KeyboardLimits? { didSet { mappingVersion += 1 } }
    /// Saved course progress: finishing a step marks it done.
    var progress: CourseProgress? { didSet { refreshNavigation() } }
    private let practiceSettings: Settings
    private let performance: PracticePerformanceStore
    private let practiceDay: () -> Int
    private var recallMode = false
    private var hintRevealed = false
    private var displayedStep: TypingStep?
    private var promptBeganAt = ProcessInfo.processInfo.systemUptime
    private var typingMode: SubMode?
    private var practicePermissionMissing = false
    private var reviewing = false
    private var reviewGeneration = 0
    private var reviewTargets: [PracticeChord] = []
    private struct Attempt {
        let step: TypingStep
        let target: PracticeChord
        let context: EngineContext
        let beganAt: Double
        var assisted: Bool
    }
    private var attempt: Attempt?
    private var chordShift = false
    private var scoredMistakes = 0
    // Ephemeral UTF-16 provenance follows edits, including suffix rewrites and corrections.
    private enum InputOrigin: Equatable {
        case chord(SubMode, Int), structural(SubMode, Int), ordinary
    }
    private var inputOrigins: [InputOrigin] = []
    private var capturedChordAttempts = 0
    private var emittedChordOutputs = 0
    private var usedAssistance = false
    private var activePracticeSeconds = 0.0
    private var activePracticeSince: Date?
    private let exerciseQueue = DispatchQueue(label: "KeyChord.practice-generation", qos: .userInitiated)
    // Accessed only on exerciseQueue; generation IDs discard results for exercises the user has left.
    private var exerciseGenerator: PracticeGenerator?
    private var generatorVersion = -1
    private var mappingVersion = 0
    private var exerciseRequest = 0
    private var practiceSource: PracticeSource?
    private var exerciseNumber = 0
    private var preparingExercise = false
    private var isExerciseScreen = false
    private var listening = false
    private var listeningPractice: ListeningPractice?
    private let speaker = PracticeSpeaker()
    private var importedText = false
    private var importedFileName: String?
    private var importLanguageSelection = 0
    private var courseStage: LearningStage = .see
    private var demonstrationSteps: [TypingStep] = []
    private var demonstrationIndex = 0
    private var demonstrationReleased = false
    private var lastAnnouncedErrorAt = -Double.infinity
    private var announcedCompletion = false
    private var lessonMappingCache: [Int: UInt64] = [:]
    private var dueCourseChecks: [Int] = []

    // Course
    /// The course step being practiced, when the text is one.
    private(set) var courseStep: Int?
    private var wasFinished = false
    private var courseCard: NSBox!
    private var learningCard: NSStackView!
    private var primaryActions: NSStackView!
    private var secondaryActions: NSStackView!
    private let learningStages = NSSegmentedControl(labels: LearningStage.allCases.map(\.title), trackingMode: .selectOne,
                                                     target: nil, action: nil)
    private let learningTitle = NSTextField(labelWithString: "See the chord")
    private let learningDetail = NSTextField(wrappingLabelWithString: "")
    private let delayedStatus = NSTextField(wrappingLabelWithString: "")
    private let delayedRulesButton = NSButton(title: "", target: nil, action: nil)
    private var delayedRulesPopover: NSPopover?
    private let demonstrateButton = NSButton(title: "Show release", target: nil, action: nil)
    private let nextExampleButton = NSButton(title: "Next example", target: nil, action: nil)
    private let stageNextButton = NSButton(title: "Try with guidance", target: nil, action: nil)
    private let stageContinueButton = NSButton(title: "Next lesson", target: nil, action: nil)
    private let delayedCheckButton = NSButton(title: "Start delayed check", target: nil, action: nil)
    private var practiceCard: NSStackView!
    private let courseTitle = NSTextField(labelWithString: "")
    private let coursePosition = NSTextField(labelWithString: "")
    private let courseIntro = NSTextField(wrappingLabelWithString: "")
    /// What the step introduces, with its keys.
    private let courseNew = NSTextField(wrappingLabelWithString: "")

    private let tapIsRunning: () -> Bool
    /// Injectable focus source lets the no-window harness exercise real scoring and edit paths.
    private let practiceFocus: (() -> Bool)?
    private var inputIsFocused: Bool {
        practiceFocus?() ?? (window?.isKeyWindow == true && window?.firstResponder === inputView)
    }
    private var data: EngineData
    private var rolloverLimit: Int
    private var mode: SubMode
    private var keyMeanings: KeyMeanings?

    // Passage
    private var text = ""
    private var chars: [Character] = []
    private var targetUTF16: [unichar] = []
    /// UTF-16 offset of each character boundary, to map planner offsets to NSRange.
    private var utf16Offsets: [Int] = [0]
    /// Character offset where each word of the passage ends, for the word counter.
    private var wordEnds: [Int] = []
    /// The plan for the whole passage.
    private var guide: TypingGuide?
    /// The plan for the rest of the line when the typed text is not where the whole-passage plan expects it,
    /// for example after part of a word and Delete ("an" of "anything": the chords for "ything").
    private var continuation: TypingContinuation?
    /// The plan being followed at the cursor: the continuation, or the whole-passage plan.
    private var active: TypingGuide?
    /// Plans continuations on the main thread, with the same data as `guide`.
    private var continuationPlanner: TypingPlanner?
    private var generation = 0

    // Progress
    private var correctUTF16 = 0
    private var correct = 0                 // characters typed correctly from the start
    private var hasError = false
    private var editFloor = Int.max         // lowest UTF-16 offset edited since the last refresh
    private var currentStep: Int?
    private var currentGroup: Int?
    /// Steps with no visible output (commands, the Delete after a throwaway letter), confirmed by the chord.
    private var doneSteps = Set<Int>()
    private var startTime: Date?
    private var finishTime: Date?
    private var mistakes = 0
    private var lastTypedLen = 0
    private var applyingChordOutput = false
    private var styled = (correct: 0, typedEnd: 0, word: NSRange(location: 0, length: 0))

    // Keys
    private var held = Set<KeyCode>()
    private var chordCodes = Set<KeyCode>()
    private var monitor: Any?

    /// Planning a 300 KB file took about 1.6 s in a release build, so 1 MB stays around 5 s.
    private static let maxFileBytes = 1_000_000
    private static let modifierCodes: Set<KeyCode> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]

    private static let sampleEnglish =
        "We are going to learn to type with chords. Press all the keys of a chord together, then let them go. "
        + "The first words are the hardest, but it gets easier with time."
    private static let sampleCpp = "int main() {\n    std::vector<int> values;\n    return 0;\n}"

    // UI
    private var passageView: NSTextView!
    private var inputView: NSTextView!
    private let keyboard = KeyboardDiagramView()
    private let languageLabel = NSTextField(labelWithString: "English")
    private let importLanguagePopup = NSPopUpButton()
    private var importLanguageRow: NSStackView!
    private let courseLanguageLabel = PracticeUI.label("English", size: 12, weight: .semibold)
    private var exerciseHeading: NSStackView!
    private let sectionTabs = NSSegmentedControl(labels: [DesignSystem.Labels.sections["learn"]!, DesignSystem.Labels.sections["practice"]!], trackingMode: .selectOne,
                                                 target: nil, action: nil)
    private var courseOverview: PracticeCourseOverview!
    private var practiceLibrary: PracticeLibraryView!
    private var exerciseContent: NSStackView!
    private var pageContent: NSStackView!
    private let newExerciseButton = NSButton(title: "New exercise", target: nil, action: nil)
    private let completionTitle = NSTextField(labelWithString: "Exercise complete")
    private let completionDetail = NSTextField(wrappingLabelWithString: "")
    private let completionNext = NSButton(title: "Next lesson", target: nil, action: nil)
    private var completionCard: NSBox!
    private var workspaceScroll: NSScrollView!
    private var passageScroll: NSScrollView!
    private var passageHeight: NSLayoutConstraint!
    private var passageCard: NSBox!
    private var keyboardCard: NSStackView!
    private var practiceControls: NSStackView!
    private var listeningCard: NSBox!
    private let listeningStatus = NSTextField(wrappingLabelWithString: "Listen to the word, then type it.")
    private let listeningCount = PracticeUI.label("0 words complete", size: 12)
    private let replayButton = NSButton(title: "Hear again", target: nil, action: nil)
    private let listeningHintButton = NSButton(title: "Show answer", target: nil, action: nil)
    private let listeningWordButton = NSButton(title: "Show word", target: nil, action: nil)
    private var listeningWordRevealed = false
    private let listeningVocabulary = NSPopUpButton()
    private let sessionProgress = NSProgressIndicator()
    private let pageTitle = NSTextField(labelWithString: "Practice")
    private let settingsButton = NSButton(title: "Settings", target: nil, action: nil)
    private let toolsButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let detailsButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let keyLabelsPopup = NSPopUpButton()
    private let textSizePopup = NSPopUpButton()
    private var settingsPopover: NSPopover?
    private let statsLabel = NSTextField(labelWithString: "")
    private let wordLabel = NSTextField(labelWithString: "")
    private let comboLabel = NSTextField(wrappingLabelWithString: "")
    /// What the current chord's keys stand for: "th (E T) · i (M) · ng (K L)".
    private let partsLabel = NSTextField(wrappingLabelWithString: "")
    private let targetStateLabel = NSTextField(wrappingLabelWithString: "")
    private let keyboardTextButton = NSButton(title: "Keys as text", target: nil, action: nil)
    private let keyboardText = PracticeKeyboardTextView()
    private var keyboardTextVisible = false
    private let hintLabel = NSTextField(wrappingLabelWithString: "")
    /// Colors of the keyboard and the keys with a job of their own.
    private let keyboardHelp = PracticeKeyboardHelp()
    private let practiceMode = NSSegmentedControl(labels: ["With hints", "From memory"], trackingMode: .selectOne,
                                                 target: nil, action: nil)
    private let hintButton = NSButton(title: "Show Hint", target: nil, action: nil)
    private let reviewButton = NSButton(title: "Review Weak Chords", target: nil, action: nil)
    private let referenceButton = NSButton(title: "Show Reference", target: nil, action: nil)
    private let practiceActiveButton = NSButton(title: "Start chord practice", target: nil, action: nil)
    private let enableOtherAppsButton = NSButton(title: "Allow chord typing…", target: nil, action: nil)
    private let lessonDetailsButton = NSButton(title: "New chords", target: nil, action: nil)
    private var lessonDetailsVisible = false
    private let typingStatus = NSTextField(wrappingLabelWithString: "Chord typing off · tap right Option to start")
    private let performanceLabel = NSTextField(labelWithString: "")
    private let historyButton = NSButton(title: "Chord history", target: nil, action: nil)
    private var historyVisible = false
    private let reviewLabel = NSTextField(wrappingLabelWithString: "")

    init(data: EngineData, rolloverLimit: Int, mode: SubMode, tapIsRunning: @escaping () -> Bool,
         defaults: UserDefaults = .standard, practiceFocus: (() -> Bool)? = nil,
         practiceDay: @escaping () -> Int = { PracticePerformanceStore.today }) {
        self.data = data
        self.rolloverLimit = rolloverLimit
        self.mode = mode
        self.tapIsRunning = tapIsRunning
        self.practiceFocus = practiceFocus
        self.practiceDay = practiceDay
        practiceSettings = Settings(defaults: defaults)
        performance = PracticePerformanceStore(defaults: defaults, day: practiceDay)
        recallMode = practiceSettings.recallPractice
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 920),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "KeyChord Typing Practice"
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 390, height: 600)
        w.titlebarAppearsTransparent = true
        w.backgroundColor = .windowBackgroundColor
        w.setFrameAutosaveName("KeyChordPracticeWorkspace")
        w.collectionBehavior.insert(.fullScreenPrimary)
        w.autorecalculatesKeyViewLoop = true
        super.init(window: w)
        w.delegate = self
        buildUI()
        installMenu()
        keyboard.layout = data.layout
        updateMeanings()
        NotificationCenter.default.addObserver(self, selector: #selector(keyLabelsChanged),
                                               name: Settings.keyLabelsDidChange, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(accessibilityDisplayChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        setText(Self.sample(for: mode), name: nil)
        showCourseOverview()
        w.center()
    }

    /// Labels the keyboard with what each key means in the current mode, and explains the colors below it.
    private func updateMeanings() {
        let m = KeyMeanings(data: data, mode: mode)
        keyMeanings = m
        keyboard.meanings = m
        keyboardHelp.update(m, layout: data.layout, style: practiceSettings.keyLabelStyle)
        languageLabel.stringValue = mode == .english ? "English" : "C++"
        courseLanguageLabel.stringValue = languageLabel.stringValue
        updatePracticeControls()
    }

    /// A compact legend for the floating overlay; the practice window has a separate, optional guide.
    static func legend(_ m: KeyMeanings, layout: Layout) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: 12)
        let out = NSMutableAttributedString()
        func add(_ s: String, _ color: NSColor = .secondaryLabelColor, bold: Bool = false) {
            out.append(NSAttributedString(string: s, attributes: [
                .font: bold ? NSFont.systemFont(ofSize: 12, weight: .semibold) : font, .foregroundColor: color]))
        }
        let roles: [(KeyMeanings.Role, String)] = [(.onset, "start"), (.vowel, "vowel"),
                                                   (.coda, "end"), (.spell, "letter"), (.special, "action")]
        for (i, (role, text)) in roles.enumerated() {
            if i > 0 { add("    ") }
            add("● ", KeyboardDiagramView.color(for: role))
            add(text)
        }
        add("\nSpace + chord", .labelColor, bold: true)
        add("  joins a word    ")
        add("Right Option", .labelColor, bold: true)
        add("  turns chord typing on or off")
        return out
    }

    required init?(coder: NSCoder) { fatalError() }

    private static func sample(for mode: SubMode) -> String { mode == .cpp ? sampleCpp : sampleEnglish }

    // MARK: UI

    private func buildUI() {
        guard let content = window?.contentView else { return }

        reviewButton.title = "Review weak chords"
        reviewButton.target = self
        reviewButton.action = #selector(reviewWeakChords)
        reviewButton.toolTip = "Practice the chords you miss or take longest to recall."
        let importButton = NSButton(title: "Use your own text…", target: self, action: #selector(importFile))
        importButton.keyEquivalent = "o"
        importButton.keyEquivalentModifierMask = [.command]
        settingsButton.target = self
        settingsButton.action = #selector(showSettings(_:))
        settingsButton.keyEquivalent = ","
        settingsButton.keyEquivalentModifierMask = [.command]
        PracticeUI.icon(settingsButton, symbol: "gearshape", label: "Settings")
        toolsButton.bezelStyle = .rounded
        toolsButton.setAccessibilityLabel("Tools")
        toolsButton.menu = NSMenu()
        toolsButton.menu?.addItem(NSMenuItem(title: "Tools", action: nil, keyEquivalent: ""))
        for (title, action) in [(DesignSystem.Labels.sections["listen"]!, #selector(openListeningTool)),
                                (DesignSystem.Labels.sections["editor"]!, #selector(openEditorTool)),
                                (DesignSystem.Labels.sections["reference"]!, #selector(openReferenceTool)),
                                (DesignSystem.Labels.sections["hardware"]!, #selector(openKeyboardTool)),
                                (DesignSystem.Labels.sections["settings"]!, #selector(openSettingsTool))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            toolsButton.menu?.addItem(item)
        }
        textSizePopup.addItems(withTitles: Settings.practiceTextSizeRange.map { "\($0) pt" })
        textSizePopup.selectItem(at: practiceSettings.practiceTextSize - Settings.practiceTextSizeRange.lowerBound)
        textSizePopup.target = self
        textSizePopup.action = #selector(selectTextSize)

        sectionTabs.target = self
        sectionTabs.action = #selector(sectionChanged)
        sectionTabs.selectedSegment = 0
        sectionTabs.segmentStyle = .rounded
        sectionTabs.setWidth(76, forSegment: 0)
        sectionTabs.setWidth(76, forSegment: 1)
        sectionTabs.heightAnchor.constraint(equalToConstant: 32).isActive = true
        sectionTabs.setAccessibilityLabel(DesignSystem.Labels.sections["learn"]! + " or " + DesignSystem.Labels.sections["practice"]!)
        let brand = PracticeUI.label("KeyChord", size: CGFloat(DesignSystem.Typography.brand), weight: .bold)
        brand.textColor = .labelColor
        let header = PracticeUI.row([brand, PracticeUI.spacer(), sectionTabs, PracticeUI.spacer(), toolsButton])
        header.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(header)
        let headerLine = NSBox()
        headerLine.boxType = .separator
        headerLine.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(headerLine)
        workspaceScroll = NSScrollView()
        workspaceScroll.drawsBackground = false
        workspaceScroll.borderType = .noBorder
        workspaceScroll.hasVerticalScroller = true
        workspaceScroll.autohidesScrollers = true
        workspaceScroll.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(workspaceScroll)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: CGFloat(DesignSystem.Metrics.pagePadding)),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -CGFloat(DesignSystem.Metrics.pagePadding)),
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            header.heightAnchor.constraint(equalToConstant: 36),
            headerLine.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            headerLine.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            headerLine.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            headerLine.heightAnchor.constraint(equalToConstant: 1),
            workspaceScroll.topAnchor.constraint(equalTo: headerLine.bottomAnchor),
            workspaceScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            workspaceScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            workspaceScroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        pageTitle.font = .systemFont(ofSize: CGFloat(DesignSystem.Typography.title), weight: .semibold)
        pageTitle.lineBreakMode = .byTruncatingTail
        pageTitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pageTitle.heightAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true
        languageLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        languageLabel.textColor = PracticeUI.accentColor
        languageLabel.toolTip = "Built-in exercises keep their intended language. Imported text can use Auto, English, or C++."
        languageLabel.setAccessibilityLabel("Exercise language")
        languageLabel.setContentHuggingPriority(.required, for: .horizontal)
        languageLabel.heightAnchor.constraint(equalToConstant: 26).isActive = true
        exerciseHeading = PracticeUI.row([pageTitle, PracticeUI.spacer(), languageLabel])
        importLanguagePopup.addItems(withTitles: ["Auto", "English", "C++"])
        importLanguagePopup.target = self
        importLanguagePopup.action = #selector(importLanguageChanged)
        importLanguagePopup.setAccessibilityLabel("Imported text language")
        importLanguagePopup.setAccessibilityHelp("Auto detects the language. Choose English or C++ to override it; your text and draft stay in memory.")
        importLanguageRow = PracticeUI.row([PracticeUI.label("Text language"), importLanguagePopup, PracticeUI.spacer()])
        importLanguageRow.isHidden = true
        let backButton = NSButton(title: "‹ All lessons", target: self, action: #selector(backToOverview))
        backButton.bezelStyle = .rounded
        backButton.heightAnchor.constraint(equalToConstant: 36).isActive = true
        backButton.setAccessibilityIdentifier("practice-back")
        newExerciseButton.target = self
        newExerciseButton.action = #selector(newExercise)
        newExerciseButton.bezelStyle = .rounded
        newExerciseButton.heightAnchor.constraint(equalToConstant: 36).isActive = true
        newExerciseButton.keyEquivalent = "g"
        newExerciseButton.keyEquivalentModifierMask = [.command]
        newExerciseButton.toolTip = "Generate a fresh exercise (⌘G)"
        let exerciseNavigation = PracticeUI.row([backButton, PracticeUI.spacer(), newExerciseButton])
        practiceMode.target = self
        practiceMode.action = #selector(recallChanged)
        practiceMode.selectedSegment = recallMode ? 1 : 0
        practiceMode.segmentStyle = .rounded
        practiceMode.heightAnchor.constraint(equalToConstant: 32).isActive = true
        practiceMode.setAccessibilityLabel("Practice with hints or from memory")
        let restartButton = NSButton(title: "", target: self, action: #selector(restart))
        PracticeUI.icon(restartButton, symbol: "arrow.counterclockwise", label: "Retry this exercise (⌘R)")
        restartButton.keyEquivalent = "r"
        restartButton.keyEquivalentModifierMask = [.command]
        referenceButton.title = "Keyboard guide"
        referenceButton.target = self
        referenceButton.action = #selector(toggleReference)
        referenceButton.bezelStyle = .rounded
        referenceButton.heightAnchor.constraint(equalToConstant: 32).isActive = true
        practiceControls = PracticeUI.row([practiceMode, PracticeUI.spacer()])

        reviewLabel.font = .systemFont(ofSize: 12)
        reviewLabel.textColor = .secondaryLabelColor
        reviewLabel.isHidden = true

        // Lesson context, its new chords and navigation form one compact section.
        courseTitle.font = .systemFont(ofSize: 18, weight: .semibold)
        courseTitle.lineBreakMode = .byWordWrapping
        courseTitle.maximumNumberOfLines = 2
        coursePosition.font = .systemFont(ofSize: 11, weight: .medium)
        coursePosition.textColor = .secondaryLabelColor
        courseIntro.font = .systemFont(ofSize: 13)
        courseIntro.textColor = .secondaryLabelColor
        courseNew.maximumNumberOfLines = 0
        coursePosition.lineBreakMode = .byTruncatingTail
        coursePosition.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        courseLanguageLabel.textColor = PracticeUI.accentColor
        courseLanguageLabel.setAccessibilityLabel("Lesson language, fixed by the course")
        courseLanguageLabel.heightAnchor.constraint(equalToConstant: 22).isActive = true
        let courseHeading = PracticeUI.row([coursePosition, PracticeUI.spacer(), courseLanguageLabel])
        lessonDetailsButton.target = self
        lessonDetailsButton.action = #selector(toggleLessonDetails)
        lessonDetailsButton.bezelStyle = .rounded
        courseCard = PracticeUI.surface(PracticeUI.column([courseHeading, courseIntro, courseNew], spacing: 8))
        courseCard.isHidden = true
        courseCard.setAccessibilityLabel("Current lesson")
        learningStages.target = self
        learningStages.action = #selector(learningStageChanged)
        learningStages.segmentStyle = .rounded
        learningStages.setAccessibilityLabel("Lesson stages: See, Try, Recall, Use")
        learningStages.setAccessibilityHelp("See models physical keys and release. Try gives guidance. Recall starts a fresh unaided exercise. Use opens an optional editor task.")
        learningStages.heightAnchor.constraint(equalToConstant: 32).isActive = true
        learningTitle.font = .systemFont(ofSize: 16, weight: .semibold)
        learningDetail.font = .systemFont(ofSize: 13)
        delayedStatus.font = .systemFont(ofSize: 12)
        delayedStatus.textColor = .secondaryLabelColor
        delayedStatus.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        delayedRulesButton.target = self
        delayedRulesButton.action = #selector(showDelayedRules(_:))
        PracticeUI.icon(delayedRulesButton, symbol: "questionmark.circle", label: "How delayed checks earn retention")
        delayedRulesButton.setAccessibilityHelp("Retention requires three successful due checks on later days spanning at least four days. Same-day repetitions do not count. Open for all rules.")
        for button in [demonstrateButton, stageNextButton, stageContinueButton, delayedCheckButton, nextExampleButton] {
            button.target = self
            button.bezelStyle = .rounded
            button.heightAnchor.constraint(equalToConstant: 36).isActive = true
        }
        demonstrateButton.action = #selector(advanceDemonstration)
        nextExampleButton.action = #selector(advanceDemonstration)
        stageNextButton.action = #selector(advanceLearningStage)
        stageContinueButton.action = #selector(continueCourseAfterUse)
        delayedCheckButton.action = #selector(startDelayedCheck)
        learningCard = PracticeUI.column([learningStages, learningDetail], spacing: 12)
        learningCard.isHidden = true

        // A bounded passage preview keeps short lessons short and long imports scrollable.
        passageScroll = NSTextView.scrollableTextView()
        passageView = passageScroll.documentView as? NSTextView
        passageView.isEditable = false
        passageView.isSelectable = false
        passageView.isRichText = false
        passageView.drawsBackground = false
        passageView.textContainerInset = NSSize(width: 0, height: 8)
        passageView.setAccessibilityLabel("Text to type")
        passageScroll.drawsBackground = false
        passageScroll.hasVerticalScroller = true
        passageScroll.autohidesScrollers = true
        passageScroll.borderType = .noBorder
        passageHeight = passageScroll.heightAnchor.constraint(equalToConstant: 54)
        passageHeight.isActive = true
        statsLabel.textColor = .secondaryLabelColor
        statsLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        statsLabel.alignment = .right
        statsLabel.lineBreakMode = .byTruncatingHead
        statsLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let passageTop = PracticeUI.row([PracticeUI.label("Type this", size: 12), PracticeUI.spacer()])
        sessionProgress.isIndeterminate = false
        sessionProgress.style = .bar
        sessionProgress.controlSize = .small
        sessionProgress.minValue = 0
        sessionProgress.maxValue = 1
        sessionProgress.heightAnchor.constraint(equalToConstant: 4).isActive = true
        sessionProgress.setAccessibilityLabel("Passage progress")
        passageCard = PracticeUI.surface(PracticeUI.column([passageTop, passageScroll], spacing: 4))

        replayButton.target = self
        replayButton.action = #selector(replayWord)
        replayButton.bezelStyle = .rounded
        replayButton.heightAnchor.constraint(equalToConstant: 36).isActive = true
        replayButton.keyEquivalent = "r"
        replayButton.keyEquivalentModifierMask = [.command, .shift]
        replayButton.toolTip = "Hear the word again (⌘⇧R)"
        listeningHintButton.target = self
        listeningHintButton.action = #selector(revealHint)
        listeningHintButton.bezelStyle = .rounded
        listeningHintButton.heightAnchor.constraint(equalToConstant: 36).isActive = true
        listeningHintButton.keyEquivalent = "h"
        listeningHintButton.keyEquivalentModifierMask = [.command, .shift]
        listeningHintButton.toolTip = "Reveal the word and all its chords (⌘⇧H)"
        listeningWordButton.target = self
        listeningWordButton.action = #selector(revealListeningWord)
        listeningWordButton.bezelStyle = .rounded
        listeningWordButton.toolTip = "Reveal the text to practice without audio; this counts as assistance."
        listeningStatus.font = .systemFont(ofSize: 20, weight: .semibold)
        listeningVocabulary.addItems(withTitles: ["My learned chords", "All vocabulary"])
        listeningVocabulary.target = self
        listeningVocabulary.action = #selector(listeningVocabularyChanged)
        listeningVocabulary.setAccessibilityLabel("Listening vocabulary")
        listeningCard = PracticeUI.surface(PracticeUI.column([
            PracticeUI.row([listeningVocabulary, PracticeUI.spacer(), listeningCount]), listeningStatus,
            PracticeUI.row([replayButton, listeningWordButton, listeningHintButton, PracticeUI.spacer()]),
        ], spacing: 12))
        listeningCard.isHidden = true
        speaker.onSpeakingChanged = { [weak self] speaking in
            DispatchQueue.main.async {
                guard let self, self.listening, self.listeningPractice?.isComplete == false else { return }
                self.listeningStatus.stringValue = speaking ? "Listen…" : "Type the word you heard."
            }
        }

        // The word, current chord and its explanation stay together above the input.
        wordLabel.font = .systemFont(ofSize: 28, weight: .semibold)
        wordLabel.heightAnchor.constraint(equalToConstant: 36).isActive = true
        wordLabel.lineBreakMode = .byTruncatingTail
        wordLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        comboLabel.font = .monospacedSystemFont(ofSize: 18, weight: .medium)
        comboLabel.maximumNumberOfLines = 0
        comboLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        comboLabel.setAccessibilityLabel("Chords for the current word")
        partsLabel.font = .systemFont(ofSize: 13)
        partsLabel.maximumNumberOfLines = 0
        partsLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        partsLabel.setAccessibilityLabel("What the chord means")
        targetStateLabel.font = .systemFont(ofSize: 12)
        targetStateLabel.textColor = .labelColor
        targetStateLabel.setAccessibilityLabel("Current physical keys and held state")
        hintLabel.font = .systemFont(ofSize: 12)
        hintLabel.textColor = .secondaryLabelColor
        hintButton.target = self
        hintButton.action = #selector(revealHint)
        hintButton.keyEquivalent = "h"
        hintButton.keyEquivalentModifierMask = [.command, .shift]
        hintButton.controlSize = .small
        hintButton.toolTip = "Reveal the current chord (⌘⇧H)"
        let prompt = PracticeUI.column([comboLabel, hintLabel], spacing: 6)

        let inputScroll = NSScrollView()
        let input = PracticeInputView(frame: NSRect(x: 0, y: 0, width: 600, height: 64))
        input.isVerticallyResizable = true
        input.isHorizontallyResizable = false
        input.autoresizingMask = [.width]
        input.textContainer?.widthTracksTextView = true
        input.textContainer?.containerSize = NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude)
        inputView = input
        inputScroll.documentView = input
        inputView.isRichText = false
        inputView.drawsBackground = false
        inputView.allowsUndo = true
        inputView.font = .systemFont(ofSize: 20)
        inputView.textContainerInset = NSSize(width: 0, height: 8)
        inputView.isAutomaticQuoteSubstitutionEnabled = false
        inputView.isAutomaticDashSubstitutionEnabled = false
        inputView.isAutomaticTextReplacementEnabled = false
        inputView.isAutomaticSpellingCorrectionEnabled = false
        inputView.isContinuousSpellCheckingEnabled = false
        inputView.isGrammarCheckingEnabled = false
        inputView.isAutomaticTextCompletionEnabled = false
        inputView.smartInsertDeleteEnabled = false
        inputView.delegate = self
        inputView.setAccessibilityLabel("Practice input")
        inputScroll.drawsBackground = false
        inputScroll.hasVerticalScroller = true
        inputScroll.autohidesScrollers = true
        inputScroll.borderType = .noBorder
        inputScroll.heightAnchor.constraint(equalToConstant: 64).isActive = true
        typingStatus.font = .systemFont(ofSize: 11, weight: .medium)
        typingStatus.lineBreakMode = .byWordWrapping
        typingStatus.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        performanceLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        performanceLabel.textColor = .secondaryLabelColor
        performanceLabel.alignment = .right
        performanceLabel.lineBreakMode = .byTruncatingTail
        performanceLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        practiceActiveButton.target = self
        practiceActiveButton.action = #selector(togglePracticeActive)
        practiceActiveButton.bezelStyle = .rounded
        practiceActiveButton.heightAnchor.constraint(equalToConstant: 32).isActive = true
        enableOtherAppsButton.target = self
        enableOtherAppsButton.action = #selector(enableOtherApps)
        enableOtherAppsButton.bezelStyle = .rounded
        enableOtherAppsButton.heightAnchor.constraint(equalToConstant: 32).isActive = true
        enableOtherAppsButton.isHidden = true
        enableOtherAppsButton.setAccessibilityHelp("Explicitly opt into typing outside KeyChord and open the required macOS permission steps.")
        historyButton.target = self
        historyButton.action = #selector(toggleHistory)
        historyButton.bezelStyle = .rounded
        historyButton.controlSize = .small
        let inputCard = PracticeUI.surface(inputScroll)
        input.onFocusChange = { [weak self, weak inputCard] focused in
            inputCard?.borderColor = focused ? PracticeUI.accentColor.withAlphaComponent(0.5)
                                            : NSColor.separatorColor.withAlphaComponent(0.45)
            self?.attempt = nil
            self?.promptBeganAt = ProcessInfo.processInfo.systemUptime
            if focused { self?.resumePracticeTimer() } else { self?.pausePracticeTimer() }
        }
        practiceCard = PracticeUI.column([inputCard, typingStatus], spacing: 8)
        detailsButton.bezelStyle = .rounded
        detailsButton.controlSize = .small
        detailsButton.setAccessibilityLabel("Exercise details")
        detailsButton.menu = NSMenu()
        detailsButton.menu?.addItem(NSMenuItem(title: "Details", action: nil, keyEquivalent: ""))
        for (title, action) in [("Lesson details", #selector(toggleLessonDetails)),
                                ("Key meanings", #selector(toggleReference)),
                                ("Keys as text", #selector(toggleKeyboardText)),
                                ("Chord history", #selector(toggleHistory)),
                                ("Progress and later checks", #selector(showExerciseProgress)),
                                ("Start due check", #selector(startDelayedCheck))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            detailsButton.menu?.addItem(item)
        }
        primaryActions = PracticeUI.row([demonstrateButton, stageNextButton, practiceActiveButton, enableOtherAppsButton,
                                         PracticeUI.spacer()])
        secondaryActions = PracticeUI.row([hintButton, restartButton, nextExampleButton, stageContinueButton,
                                           PracticeUI.spacer(), detailsButton])

        keyboard.showsFunctionRow = false
        keyboard.emphasizesCurrentChord = true
        keyboard.translatesAutoresizingMaskIntoConstraints = false
        keyboard.heightAnchor.constraint(equalTo: keyboard.widthAnchor, multiplier: KeyboardDiagramView.compactAspect).isActive = true
        let keyboardHost = NSView()
        keyboardHost.addSubview(keyboard)
        let keyboardWidth = keyboard.widthAnchor.constraint(equalToConstant: CGFloat(DesignSystem.Metrics.keyboardWidth))
        keyboardWidth.priority = .init(490)
        NSLayoutConstraint.activate([
            keyboard.centerXAnchor.constraint(equalTo: keyboardHost.centerXAnchor),
            keyboard.topAnchor.constraint(equalTo: keyboardHost.topAnchor),
            keyboard.bottomAnchor.constraint(equalTo: keyboardHost.bottomAnchor),
            keyboard.widthAnchor.constraint(lessThanOrEqualTo: keyboardHost.widthAnchor),
            keyboard.widthAnchor.constraint(lessThanOrEqualToConstant: CGFloat(DesignSystem.Metrics.keyboardWidth)),
            keyboardWidth,
        ])
        keyboardTextButton.target = self
        keyboardTextButton.action = #selector(toggleKeyboardText)
        keyboardTextButton.bezelStyle = .rounded
        keyboardTextButton.controlSize = .small
        keyboardText.isHidden = true
        keyboardCard = PracticeUI.column([keyboardHost, keyboardText, keyboardHelp], spacing: 10)
        completionTitle.font = .systemFont(ofSize: 22, weight: .semibold)
        completionDetail.font = .systemFont(ofSize: 13)
        completionDetail.textColor = .secondaryLabelColor
        completionNext.target = self
        completionNext.action = #selector(continueAfterExercise)
        completionNext.bezelStyle = .rounded
        completionNext.bezelColor = PracticeUI.accentColor
        completionNext.heightAnchor.constraint(equalToConstant: CGFloat(DesignSystem.Metrics.actionHeight)).isActive = true
        completionCard = PracticeUI.surface(PracticeUI.column([completionTitle, completionDetail, completionNext], spacing: 12),
                                           padding: 20, accented: true)
        completionCard.isHidden = true
        exerciseContent = PracticeUI.column([exerciseNavigation, exerciseHeading, learningCard, practiceControls, importLanguageRow, reviewLabel,
                                             listeningCard, passageCard, practiceCard, primaryActions, completionCard,
                                             secondaryActions, prompt, courseCard, performanceLabel, keyboardCard], spacing: 14)
        courseOverview = PracticeCourseOverview()
        courseOverview.onLesson = { [weak self] index in self?.openCourseStep(index) }
        courseOverview.onContinue = { [weak self] in self?.startCourse() }
        courseOverview.onReview = { [weak self] in self?.reviewWeakChords() }
        courseOverview.onDelayedCheck = { [weak self] in
            guard let self, let index = self.dueCourseChecks.first else { return }
            self.openCourseStep(index)
            self.selectLearningStage(.recall)
        }
        practiceLibrary = PracticeLibraryView(review: reviewButton, importButton: importButton)
        practiceLibrary.onTopic = { [weak self] index in self?.startGeneratedExercise(.topic(index)) }
        practiceLibrary.onListen = { [weak self] in self?.startListeningPractice() }
        exerciseContent.isHidden = true
        practiceLibrary.isHidden = true
        pageContent = PracticeUI.column([courseOverview, practiceLibrary, exerciseContent], spacing: 0)
        pageContent.translatesAutoresizingMaskIntoConstraints = false
        let document = PracticeDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        workspaceScroll.documentView = document
        document.addSubview(pageContent)
        let clip = workspaceScroll.contentView
        let preferredWidth = pageContent.widthAnchor.constraint(equalToConstant: CGFloat(DesignSystem.Metrics.exerciseWidth))
        preferredWidth.priority = .init(490)
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            document.topAnchor.constraint(equalTo: clip.topAnchor),
            document.widthAnchor.constraint(equalTo: clip.widthAnchor),
            pageContent.widthAnchor.constraint(lessThanOrEqualTo: document.widthAnchor, constant: -48),
            pageContent.widthAnchor.constraint(lessThanOrEqualToConstant: CGFloat(DesignSystem.Metrics.exerciseWidth)),
            preferredWidth,
            pageContent.centerXAnchor.constraint(equalTo: document.centerXAnchor),
            pageContent.topAnchor.constraint(equalTo: document.topAnchor, constant: 24),
            pageContent.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -24),
        ])
        refreshNavigation()
    }

    private func refreshNavigation() {
        let unassisted = progress?.unassisted ?? []
        var retained = Set<String>()
        dueCourseChecks = []
        for (index, step) in Course.steps.enumerated() where unassisted.contains(step.id) {
            if let check = progress?.delayedCheck(step.id, mapping: lessonMapping(at: index)) {
                if check.isRetained { retained.insert(step.id) }
                if check.isDue(day: practiceDay()) { dueCourseChecks.append(index) }
            }
        }
        courseOverview?.update(completed: progress?.completed ?? [], resume: progress?.resumeIndex ?? 0,
            dueReviewCount: dueReviewCount(mode: .english), unassisted: unassisted,
            retained: retained, dueLessonChecks: dueCourseChecks.count)
    }

    private func dueReviewCount(mode: SubMode) -> Int {
        let usable = limits.map { $0.usable(in: data.layout) } ?? { _ in true }
        return performance.history.dueCount(mode: mode, day: practiceDay(),
                                          data: data, rolloverLimit: rolloverLimit, usable: usable)
    }

    /// Standard macOS menus also provide NSTextView's clipboard and editing shortcuts.
    private func installMenu() {
        let main = NSMenu()
        func menu(_ title: String) -> NSMenu {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: title)
            item.submenu = submenu
            main.addItem(item)
            return submenu
        }
        func add(_ title: String, _ action: Selector, _ key: String, to menu: NSMenu,
                 target: AnyObject? = nil, modifiers: NSEvent.ModifierFlags = [.command]) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = target
            item.keyEquivalentModifierMask = modifiers
            menu.addItem(item)
        }
        let application = menu("KeyChord")
        add("About KeyChord", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), "", to: application, target: NSApp)
        application.addItem(.separator())
        add("Settings…", #selector(openPracticeSettings), ",", to: application, target: self)
        application.addItem(.separator())
        add("Hide KeyChord", #selector(NSApplication.hide(_:)), "h", to: application, target: NSApp)
        add("Quit KeyChord", #selector(NSApplication.terminate(_:)), "q", to: application, target: NSApp)

        let file = menu("File")
        add("Continue Course", #selector(resumeCourse), "", to: file, target: self)
        add("Practice", #selector(openPracticeTexts), "", to: file, target: self)
        add("Import Text…", #selector(importFile), "o", to: file, target: self)
        file.addItem(.separator())
        add("Restart Practice", #selector(restart), "r", to: file, target: self)
        add("Previous Lesson", #selector(previousStep), "[", to: file, target: self)
        add("Next Lesson", #selector(nextStep), "]", to: file, target: self)
        add("Close Window", #selector(NSWindow.performClose(_:)), "w", to: file)

        let edit = menu("Edit")
        add("Undo", NSSelectorFromString("undo:"), "z", to: edit)
        add("Redo", NSSelectorFromString("redo:"), "z", to: edit, modifiers: [.command, .shift])
        edit.addItem(.separator())
        add("Cut", #selector(NSText.cut(_:)), "x", to: edit)
        add("Copy", #selector(NSText.copy(_:)), "c", to: edit)
        add("Paste", #selector(NSText.paste(_:)), "v", to: edit)
        add("Select All", #selector(NSText.selectAll(_:)), "a", to: edit)

        let view = menu("View")
        add("Keyboard Reference", #selector(toggleReference), "", to: view, target: self)
        add("Show Chord Answer", #selector(revealHint), "h", to: view, target: self, modifiers: [.command, .shift])
        add("Hear Word Again", #selector(replayWord), "r", to: view, target: self, modifiers: [.command, .shift])
        add("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", to: view, modifiers: [.command, .control])
        NSApp.mainMenu = main
    }

    @objc private func openPracticeSettings() {
        present()
        showSettings(toolsButton)
    }

    @objc private func openPracticeTexts() {
        showPracticeLibrary()
        present()
    }

    @objc private func resumeCourse() { startCourse() }

    @objc private func sectionChanged() {
        if sectionTabs.selectedSegment == 0 { showCourseOverview() } else { showPracticeLibrary() }
    }

    @objc private func openListeningTool() { startListeningPractice() }
    @objc private func openEditorTool() { onUseInEditor?() }
    @objc private func openReferenceTool() {
        if isExerciseScreen && recallMode { usedAssistance = true; attempt?.assisted = true }
        onOpenReference?()
    }
    @objc private func openKeyboardTool() { onOpenKeyboardTools?() }
    @objc private func openSettingsTool() { showSettings(toolsButton) }
    @objc private func showExerciseProgress() { showDelayedRules(detailsButton) }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(openEditorTool): return onUseInEditor != nil
        case #selector(openReferenceTool): return onOpenReference != nil
        case #selector(openKeyboardTool): return onOpenKeyboardTools != nil
        case #selector(toggleLessonDetails):
            menuItem.title = lessonDetailsVisible ? "Hide lesson details" : "Lesson details"
            return courseStep != nil
        case #selector(toggleReference):
            menuItem.state = practiceSettings.practiceReferenceVisible ? .on : .off
            return !answersHidden
        case #selector(toggleKeyboardText):
            menuItem.state = keyboardTextVisible ? .on : .off
            return !answersHidden
        case #selector(toggleHistory):
            menuItem.state = historyVisible ? .on : .off
            return !performanceLabel.stringValue.isEmpty
        case #selector(startDelayedCheck): return !delayedCheckButton.isHidden
        default: return true
        }
    }

    private func showCourseOverview() {
        pausePracticeTimer()
        stopListeningPractice()
        isExerciseScreen = false
        sectionTabs.selectedSegment = 0
        courseOverview.isHidden = false
        practiceLibrary.isHidden = true
        exerciseContent.isHidden = true
        refreshNavigation()
        showPageTop()
        onFocus?(false)
    }

    private func showPracticeLibrary() {
        pausePracticeTimer()
        stopListeningPractice()
        isExerciseScreen = false
        sectionTabs.selectedSegment = 1
        courseOverview.isHidden = true
        practiceLibrary.isHidden = false
        exerciseContent.isHidden = true
        updatePracticeControls()
        showPageTop()
        onFocus?(false)
    }

    private func showExercise() {
        isExerciseScreen = true
        sectionTabs.selectedSegment = courseStep == nil ? 1 : 0
        courseOverview.isHidden = true
        practiceLibrary.isHidden = true
        exerciseContent.isHidden = false
        if let back = exerciseContent.arrangedSubviews.first as? NSStackView,
           let button = back.arrangedSubviews.first as? NSButton {
            button.title = courseStep == nil ? "‹ All practice" : "‹ All lessons"
        }
        showPageTop()
        if window?.isKeyWindow == true { onFocus?(true) }
    }

    private func showPageTop() {
        window?.contentView?.layoutSubtreeIfNeeded()
        workspaceScroll.contentView.scroll(to: .zero)
        workspaceScroll.reflectScrolledClipView(workspaceScroll.contentView)
    }

    @objc private func backToOverview() {
        if courseStep == nil { showPracticeLibrary() } else { showCourseOverview() }
    }

    private func selectPracticeLanguage(_ selected: SubMode) {
        mode = selected
        onPracticeModeChanged?(selected)
        updateMeanings()
    }

    private func startListeningPractice() {
        importedText = false
        stopListeningPractice()
        listening = true
        listeningPractice = nil
        preparingExercise = true
        practiceSource = nil
        courseStep = nil
        wasFinished = false
        exerciseRequest += 1
        let request = exerciseRequest
        setText("", name: "Listen and type", language: .english, planned: TypingGuide(mode: .english, steps: []))
        showCourseStep()
        showExercise()
        inputView.isEditable = false
        newExerciseButton.isEnabled = false
        listeningStatus.stringValue = "Preparing words…"
        listeningCount.stringValue = "0 words complete"
        updatePracticeControls()
        let data = self.data, limit = rolloverLimit
        let learned = listeningVocabulary.indexOfSelectedItem == 1 ? nil
            : Course.learnedSkills(completedIDs: progress?.completed ?? [], data: data, mode: .english)
        let usable = limits.map { $0.usable(in: data.layout) } ?? { _ in true }
        exerciseQueue.async { [weak self] in
            let session = ListeningPractice(data: data, rolloverLimit: limit, usable: usable,
                                            learnedSkills: learned, sessionLength: 10)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.listening, request == self.exerciseRequest else { return }
                self.preparingExercise = false
                self.newExerciseButton.isEnabled = true
                guard session.isAvailable else {
                    self.listeningStatus.stringValue = "No words match yet. Practice the first lesson, or choose All vocabulary above."
                    self.inputView.isEditable = false
                    self.updatePracticeControls()
                    return
                }
                self.listeningPractice = session
                self.nextListeningWord()
            }
        }
    }

    private func stopListeningPractice() {
        guard listening else { return }
        listening = false
        listeningPractice = nil
        exerciseRequest += 1
        preparingExercise = false
        newExerciseButton.isEnabled = true
        speaker.stop()
    }

    private func nextListeningWord() {
        guard listening, !preparingExercise, let session = listeningPractice else { return }
        guard session.prompt == nil || session.canAdvance else { return }
        var random = SystemRandomNumberGenerator()
        guard let prompt = session.next(using: &random) else {
            finishListeningSession(session)
            return
        }
        exerciseRequest += 1 // Cancel an earlier prompt's scheduled advance.
        speaker.stop()
        setText(prompt.text, name: "Listen and type", language: .english, planned: prompt.guide)
        updateListeningCount()
        returnToInput()
        replayWord()
    }

    private func finishListeningSession(_ session: ListeningPractice) {
        listeningStatus.stringValue = "Listening session complete"
        completionCard.isHidden = false
        completionTitle.stringValue = "\(session.completedWords) words practiced"
        completionDetail.stringValue = "\(session.assistedWords) words with hints. Return to Practice for another session."
        completionNext.title = "Choose another skill"
        inputView.isEditable = false
        newExerciseButton.isEnabled = false
        replayButton.isEnabled = false
        listeningHintButton.isEnabled = false
        listeningWordButton.isEnabled = false
    }

    private func updateListeningCount() {
        guard let session = listeningPractice else { return }
        let word = session.completedWords == 1 ? "word" : "words"
        listeningCount.stringValue = "\(session.completedWords)/\(session.sessionLength ?? 10) \(word) complete · \(session.assistedWords) with hints"
    }

    @objc private func revealListeningWord() {
        guard listening, let session = listeningPractice, !session.isComplete, let prompt = session.prompt else { return }
        session.revealHint()
        usedAssistance = true
        listeningWordRevealed = true
        listeningStatus.stringValue = "Type “\(prompt.text)”. The chord answer stays hidden until you choose Show answer."
        refreshProgress()
        returnToInput()
    }

    @objc private func listeningVocabularyChanged() { if listening { startListeningPractice() } }

    @objc private func replayWord() {
        guard listening, isExerciseScreen, !preparingExercise, window?.isKeyWindow == true,
              let session = listeningPractice, !session.isComplete, let prompt = session.prompt else { return }
        listeningStatus.stringValue = "Listen…"
        if !speaker.speak(prompt.text) {
            listeningStatus.stringValue = "Choose an English voice in macOS Speech settings, then press Hear again."
        }
        returnToInput()
    }

    private func startGeneratedExercise(_ source: PracticeSource) {
        importedText = false
        stopListeningPractice()
        preparingExercise = true
        let previous = practiceSource == source ? text : nil
        exerciseNumber = practiceSource == source ? exerciseNumber + 1 : 1
        practiceSource = source
        exerciseRequest += 1
        let request = exerciseRequest
        let title: String
        let selectedMode: SubMode
        switch source {
        case .course(let index):
            guard Course.steps.indices.contains(index) else { return }
            let step = Course.steps[index]
            courseStep = index
            progress?.lastStep = step.id
            title = step.title
            selectedMode = step.mode
        case .topic(let index):
            guard Lessons.all.indices.contains(index) else { return }
            courseStep = nil
            title = Lessons.all[index].title
            selectedMode = Lessons.all[index].mode
        }
        wasFinished = false
        setText("", name: title, language: selectedMode, planned: TypingGuide(mode: selectedMode, steps: []))
        showCourseStep()
        showExercise()
        inputView.isEditable = false
        wordLabel.stringValue = "Preparing exercise…"
        updatePracticeControls()
        newExerciseButton.isEnabled = false
        let data = self.data, limit = rolloverLimit, version = mappingVersion
        let usable = limits.map { $0.usable(in: data.layout) } ?? { _ in true }
        let seed = UInt64.random(in: UInt64.min...UInt64.max)
        exerciseQueue.async { [weak self] in
            guard let self else { return }
            if self.exerciseGenerator?.source != source || self.generatorVersion != version {
                self.exerciseGenerator = PracticeGenerator(source: source, data: data, rolloverLimit: limit, usable: usable)
                self.generatorVersion = version
            }
            let drill = self.exerciseGenerator?.next(seed: seed, avoiding: previous)
            DispatchQueue.main.async { [weak self] in
                guard let self, request == self.exerciseRequest else { return }
                self.inputView.isEditable = self.courseStep == nil || ![LearningStage.see, .use].contains(self.courseStage)
                self.newExerciseButton.isEnabled = true
                self.preparingExercise = false
                guard let drill else {
                    self.showError("This exercise is unavailable",
                        "The current chord map and keyboard limits cannot type all the skills in this exercise.")
                    self.backToOverview()
                    return
                }
                self.setText(drill.text, name: title, language: selectedMode, planned: drill.guide)
                if case .course = source { self.prepareDemonstration(drill.guide) }
                self.showCourseStep()
                if self.isExerciseScreen { self.returnToInput() }
            }
        }
    }

    @objc private func newExercise() {
        if listening { nextListeningWord() }
        else if let source = practiceSource { startGeneratedExercise(source) }
        else if !reviewTargets.isEmpty { reviewWeakChords() }
    }

    @objc private func continueAfterExercise() {
        if courseStep != nil, qualifiesForChordCredit {
            if courseStage == .tryIt || usedAssistance || max(mistakes, scoredMistakes) > 0 {
                selectLearningStage(.recall)
            } else {
                selectLearningStage(.use)
            }
            return
        }
        if qualifiesForChordCredit && usedAssistance && !listening {
            recallMode = true
            practiceMode.selectedSegment = 1
            practiceSettings.recallPractice = true
            if let source = practiceSource { startGeneratedExercise(source) }
            else { clearInput(); refreshProgress() }
        } else if let index = courseStep, index + 1 < Course.steps.count,
                  Course.steps[index + 1].mode == mode { nextStep() }
        else if practiceSource != nil || !reviewTargets.isEmpty { newExercise() }
        else { showPracticeLibrary() }
    }

    private static func title(for style: KeyLabelStyle) -> String {
        switch style {
        case .meaning: return "Key meanings"
        case .physical: return "Printed keys"
        case .both: return "Both"
        }
    }

    @objc private func showSettings(_ sender: NSButton) {
        pausePracticeTimer()
        if let popover = settingsPopover, popover.isShown {
            popover.performClose(sender)
            return
        }
        let popover = NSPopover()
        popover.behavior = .semitransient
        popover.delegate = self
        let controller = NSViewController()
        let heading = PracticeUI.label("Practice settings", size: 18, weight: .semibold)
        heading.textColor = .labelColor
        let explanation = NSTextField(wrappingLabelWithString:
            "Key meanings show the letters or actions each key represents. Printed keys match your keyboard. Both puts printed keys first.")
        explanation.font = .systemFont(ofSize: 12)
        explanation.textColor = .secondaryLabelColor
        keyLabelsPopup.removeAllItems()
        keyLabelsPopup.addItems(withTitles: KeyLabelStyle.allCases.map(Self.title(for:)))
        keyLabelsPopup.selectItem(at: KeyLabelStyle.allCases.firstIndex(of: practiceSettings.keyLabelStyle) ?? 0)
        keyLabelsPopup.target = self
        keyLabelsPopup.action = #selector(selectKeyLabels)
        keyLabelsPopup.setAccessibilityLabel("Key labels")
        textSizePopup.removeAllItems()
        textSizePopup.addItems(withTitles: Settings.practiceTextSizeRange.map { "\($0) pt" })
        textSizePopup.selectItem(at: practiceSettings.practiceTextSize - Settings.practiceTextSizeRange.lowerBound)
        textSizePopup.target = self
        textSizePopup.action = #selector(selectTextSize)
        textSizePopup.setAccessibilityLabel("Practice text size in points")
        textSizePopup.setAccessibilityHelp("Choose 16 to 30 points with the arrow keys. The passage and input resize without clearing your draft.")
        let stack = PracticeUI.column([heading, PracticeUI.label("Text size", size: 12), textSizePopup,
            PracticeUI.label("Key labels", size: 12), keyLabelsPopup, explanation], spacing: 12)
        let root = NSView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
            root.widthAnchor.constraint(equalToConstant: 320),
        ])
        controller.view = root
        popover.contentViewController = controller
        settingsPopover = popover
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxX)
    }

    @objc private func selectKeyLabels() {
        guard KeyLabelStyle.allCases.indices.contains(keyLabelsPopup.indexOfSelectedItem) else { return }
        practiceSettings.keyLabelStyle = KeyLabelStyle.allCases[keyLabelsPopup.indexOfSelectedItem]
    }

    @objc private func selectTextSize() {
        let index = textSizePopup.indexOfSelectedItem
        guard index >= 0, index < Settings.practiceTextSizeRange.count else { return }
        practiceSettings.practiceTextSize = Settings.practiceTextSizeRange.lowerBound + index
        applyTextSize()
        refreshProgress()
        announce("Practice text size \(practiceSettings.practiceTextSize) points")
    }

    private func applyTextSize() {
        let size = CGFloat(practiceSettings.practiceTextSize)
        let font: NSFont = mode == .cpp ? .monospacedSystemFont(ofSize: size, weight: .regular) : .systemFont(ofSize: size)
        inputView?.font = font
        if let storage = passageView?.textStorage {
            storage.addAttribute(.font, value: font, range: NSRange(location: 0, length: storage.length))
        }
        fitPassage()
    }

    @objc private func accessibilityDisplayChanged() {
        styled = (0, 0, NSRange(location: 0, length: targetUTF16.count))
        refreshProgress()
        keyboard.needsDisplay = true
    }

    @objc private func toggleKeyboardText() {
        keyboardTextVisible.toggle()
        keyboardText.isHidden = !keyboardTextVisible
        keyboardTextButton.title = keyboardTextVisible ? "Hide text keys" : "Keys as text"
        keyboardTextButton.setAccessibilityValue(keyboardTextVisible ? "Shown" : "Hidden")
        if keyboardTextVisible && !answersHidden {
            usedAssistance = true
            attempt?.assisted = true
        }
        if keyboardTextVisible { keyboardText.focusTable() }
    }

    @objc private func keyLabelsChanged() {
        updateMeanings()
        showCourseStep()
        refreshProgress()
    }

    func popoverDidClose(_ notification: Notification) {
        if (notification.object as? NSPopover) === delayedRulesPopover { delayedRulesPopover = nil }
        else { settingsPopover = nil }
        returnToInput()
        resumePracticeTimer()
    }

    private func fitPassage() {
        guard passageHeight != nil, let container = passageView?.textContainer, let manager = passageView?.layoutManager,
              passageScroll.bounds.width > 0 else { return }
        manager.ensureLayout(for: container)
        let height = manager.usedRect(for: container).height + passageView.textContainerInset.height * 2
        passageHeight.constant = max(44, min(72, ceil(height)))
    }

    func windowDidResize(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in self?.fitPassage() }
    }

    // MARK: Practice controls and performance

    private var answersHidden: Bool { (recallMode || listening) && !hintRevealed }

    /// Assistance follows what the learner can actually see, including persistent controls after a
    /// restart. A saved preference for a reference/table does not count while its answers are hidden.
    private var visibleAssistance: Bool {
        !(recallMode || listening) || hintRevealed
            || (courseStep != nil && lessonDetailsVisible)
            || (listening && listeningWordRevealed)
            || (!answersHidden && (practiceSettings.practiceReferenceVisible || keyboardTextVisible))
    }

    @objc private func recallChanged() {
        recallMode = practiceMode.selectedSegment == 1
        if !recallMode { usedAssistance = true; attempt?.assisted = true }
        practiceSettings.recallPractice = recallMode
        hintRevealed = false
        attempt = nil
        promptBeganAt = ProcessInfo.processInfo.systemUptime
        refreshProgress()
        returnToInput()
    }

    @objc private func revealHint() {
        guard isExerciseScreen, recallMode || listening, currentStep != nil else { return }
        if listening { listeningPractice?.revealHint() }
        hintRevealed = true
        usedAssistance = true
        attempt?.assisted = true
        refreshProgress()
        returnToInput()
    }

    @objc private func toggleReference() {
        practiceSettings.practiceReferenceVisible.toggle()
        if practiceSettings.practiceReferenceVisible && !answersHidden {
            usedAssistance = true
            attempt?.assisted = true
        }
        updatePracticeControls()
        returnToInput()
    }

    @objc private func toggleHistory() {
        historyVisible.toggle()
        updatePracticeControls()
        returnToInput()
    }

    @objc private func toggleLessonDetails() {
        lessonDetailsVisible.toggle()
        if lessonDetailsVisible && recallMode { usedAssistance = true; attempt?.assisted = true }
        updatePracticeControls()
        returnToInput()
    }

    @objc private func togglePracticeActive() {
        onPracticeActiveChanged?(typingMode != mode, mode)
        returnToInput()
    }

    @objc private func enableOtherApps() { onEnableOtherApps?() }

    private var promptContext: EngineContext {
        guard let g = active, let i = currentStep else { return .initial }
        return i > 0 ? g.steps[i - 1].contextAfter ?? .initial : continuation?.startContext ?? .initial
    }

    private func returnToInput() {
        guard isExerciseScreen else { return }
        if courseStep != nil && (courseStage == .see || courseStage == .use) {
            window?.makeFirstResponder(stageNextButton)
            return
        }
        window?.makeFirstResponder(inputView)
        // Clicking a control resets the router's spacing; resume the current chord's planned context.
        if !hasError { onSyncContext?(promptContext) }
    }

    private func updatePracticeControls() {
        guard passageCard != nil else { return }
        updatePerformanceLabel()
        let showingModel = courseStep != nil && (courseStage == .see || courseStage == .use)
        passageCard.isHidden = listening || courseStep != nil && courseStage == .use
        practiceCard.isHidden = showingModel
        if showingModel { completionCard.isHidden = true }
        listeningCard.isHidden = !listening
        practiceControls.isHidden = listening || courseStep != nil
        keyboardCard.isHidden = courseStep != nil && courseStage == .use || answersHidden
        importLanguageRow.isHidden = !importedText
        performanceLabel.isHidden = listening || !historyVisible || performanceLabel.stringValue.isEmpty
        historyButton.isHidden = listening || performanceLabel.stringValue.isEmpty
        historyButton.title = historyVisible ? "Hide chord history" : "Chord history"
        (inputView as? PracticeInputView)?.placeholder = listening ? "Type the word you hear…" : "Type the passage here…"
        wordLabel.isHidden = true
        exerciseHeading.isHidden = false
        if let index = courseStep { pageTitle.stringValue = Course.steps[index].title }
        comboLabel.isHidden = answersHidden || comboLabel.stringValue.isEmpty
        partsLabel.isHidden = true
        targetStateLabel.isHidden = true
        hintLabel.isHidden = hintLabel.stringValue.isEmpty
        if let index = courseStep {
            courseIntro.stringValue = answersHidden && !lessonDetailsVisible
                ? "Practice \(Course.steps[index].title.lowercased()) from memory. Reveal a hint when you need one."
                : Course.steps[index].intro
        }
        let hasNewChords = courseNew.attributedStringValue.string != "New in this lesson   "
        courseIntro.isHidden = !lessonDetailsVisible
        courseNew.isHidden = !lessonDetailsVisible || !hasNewChords
        courseCard.isHidden = courseStep == nil || !lessonDetailsVisible
        lessonDetailsButton.isHidden = courseStep == nil
        lessonDetailsButton.title = lessonDetailsVisible ? "Hide lesson details" : "Lesson details"
        keyboardHelp.isHidden = answersHidden || !practiceSettings.practiceReferenceVisible
        referenceButton.contentTintColor = practiceSettings.practiceReferenceVisible ? .controlAccentColor : .secondaryLabelColor
        referenceButton.title = practiceSettings.practiceReferenceVisible ? "Hide keys" : "Keyboard"
        referenceButton.setAccessibilityLabel(practiceSettings.practiceReferenceVisible ? "Hide keyboard reference" : "Show keyboard reference")
        referenceButton.setAccessibilityValue(practiceSettings.practiceReferenceVisible ? "Shown" : "Hidden")
        referenceButton.isEnabled = !answersHidden
        keyboard.meanings = answersHidden ? nil : keyMeanings
        hintButton.isHidden = !recallMode || listening
        hintButton.isEnabled = recallMode && currentStep != nil && !hintRevealed
        hintButton.title = hintRevealed ? "Hint Shown" : "Show Hint"
        listeningWordButton.isEnabled = listening && currentStep != nil && !listeningWordRevealed && !preparingExercise
        listeningHintButton.title = hintRevealed ? "Answer shown" : "Show answer"
        listeningHintButton.isEnabled = listening && currentStep != nil && !hintRevealed && !preparingExercise
        replayButton.isEnabled = listening && listeningPractice?.prompt != nil && finishTime == nil && !preparingExercise
        reviewButton.isEnabled = !reviewing && !performance.history.records.isEmpty
        if !reviewing {
            let count = dueReviewCount(mode: .english) + dueReviewCount(mode: .cpp)
            reviewButton.title = count > 0 ? "Review due · \(count) chords" : "Personal chord review"
        }
        newExerciseButton.isHidden = !listening && practiceSource == nil && reviewTargets.isEmpty
        newExerciseButton.title = listening ? "Next word" : "New exercise"
        newExerciseButton.toolTip = listening ? "Continue after answering this word (⌘G)" : "Generate a fresh exercise (⌘G)"
        if listening { newExerciseButton.isEnabled = listeningPractice?.canAdvance == true }
        if courseStep != nil {
            newExerciseButton.isHidden = courseStage == .see || courseStage == .use
            inputView.isEditable = !preparingExercise && !showingModel
        }
        practiceActiveButton.isHidden = showingModel || finishTime != nil || practicePermissionMissing
        enableOtherAppsButton.isHidden = !practicePermissionMissing || showingModel || finishTime != nil
        primaryActions.isHidden = finishTime != nil && !showingModel
        if courseStep == nil { primaryActions.isHidden = finishTime != nil }
        updateLearningStage()
    }

    private func updatePerformanceLabel() {
        guard let g = active, let i = currentStep, i < g.steps.count,
              let chord = PracticeChord(step: g.steps[i], data: data, mode: mode),
              let saved = performance.history.performance(for: chord) else {
            performanceLabel.stringValue = ""
            return
        }
        var label = "\(saved.attempts) \(saved.attempts == 1 ? "attempt" : "attempts") · \(Int((saved.accuracy * 100).rounded()))% correct"
        if let seconds = saved.averageSeconds { label += String(format: " · %.1f s", seconds) }
        if saved.hints > 0 { label += " · \(saved.hints) assisted" }
        let stage = saved.isRetained ? "Retained" : saved.isRecalled ? "Recalled" : "Practiced"
        performanceLabel.stringValue = "Chord history · " + stage + " · " + label
        performanceLabel.toolTip = "Your history with the current chord: " + stage + " · " + label
            + ". Recalled: three consecutive unaided successes. Retained: at least three successful spaced checks spanning four days."
        performanceLabel.setAccessibilityLabel("Saved performance for the current chord: " + stage + " · " + label)
    }

    /// The controller supplies the router's actual state, including permissions and Secure Input.
    func updateTypingState(availability: Availability, effectiveMode: Mode, status: String) {
        practicePermissionMissing = availability == .missingPermission
        if availability == .available, case .chord(let activeMode) = effectiveMode,
           activeMode != mode, isExerciseScreen, window?.isKeyWindow == true {
            onPracticeModeChanged?(mode)
            if !hasError { onSyncContext?(promptContext) }
            return
        }
        let previousMode = typingMode
        typingMode = nil
        switch availability {
        case .missingPermission, .secureInput:
            typingStatus.stringValue = status
            typingStatus.textColor = .systemOrange
        case .available:
            if case .chord(let activeMode) = effectiveMode {
                typingMode = activeMode
                if activeMode == mode {
                    typingStatus.stringValue = "Typing is active."
                    typingStatus.textColor = .secondaryLabelColor
                } else {
                    typingStatus.stringValue = "Chord typing on · switch to \(mode == .english ? "English" : "C++") to practice"
                    typingStatus.textColor = .systemOrange
                }
            } else {
                typingStatus.stringValue = status == "Chord typing is off"
                    ? "Chord typing off · tap right Option to start" : status
                typingStatus.textColor = .secondaryLabelColor
            }
        }
        typingStatus.setAccessibilityLabel(typingStatus.stringValue)
        if previousMode != typingMode {
            pausePracticeTimer()
            attempt = nil
            promptBeganAt = ProcessInfo.processInfo.systemUptime
        }
        practiceActiveButton.title = typingMode == mode ? "Pause" : "Start typing"
        practiceActiveButton.isEnabled = availability == .available && !preparingExercise && !status.hasPrefix("Paused")
        practiceActiveButton.toolTip = availability == .available
            ? "Turn chord typing on or off for this exercise." : status
        let showingModel = courseStep != nil && (courseStage == .see || courseStage == .use)
        practiceActiveButton.isHidden = showingModel || finishTime != nil || practicePermissionMissing
        enableOtherAppsButton.isHidden = !practicePermissionMissing || showingModel || finishTime != nil
        enableOtherAppsButton.isEnabled = onEnableOtherApps != nil
        typingStatus.isHidden = availability == .available && (typingMode == mode || status == "Chord typing is off" || status.isEmpty)
        inputView.setAccessibilityHelp(typingStatus.stringValue)
        resumePracticeTimer()
    }

    private func clearReview() {
        reviewGeneration += 1
        reviewing = false
        reviewTargets.removeAll()
        reviewLabel.isHidden = true
        reviewButton.title = "Review weak chords"
    }

    @objc private func reviewWeakChords() {
        importedText = false
        guard !reviewing else { return }
        let day = PracticePerformanceStore.today
        let usable = limits.map { $0.usable(in: self.data.layout) } ?? { _ in true }
        let validHistory = performance.history.records.filter { record in
            guard let mode = SubMode(rawValue: record.chord.mode) else { return false }
            return record.attempts > 0 && record.chord.codes.count <= rolloverLimit
                && record.chord.keys(in: self.data, mode: mode, usable: usable) != nil
        }
        let dueMode: SubMode? = dueReviewCount(mode: .english) > 0 ? .english : dueReviewCount(mode: .cpp) > 0 ? .cpp : nil
        guard let reviewMode = dueMode ?? validHistory.max(by: { $0.reviewPriority < $1.reviewPriority })
            .flatMap({ SubMode(rawValue: $0.chord.mode) }) else { return }
        stopListeningPractice()
        exerciseRequest += 1
        practiceSource = nil
        courseStep = nil
        showCourseStep()
        selectPracticeLanguage(reviewMode)
        showExercise()
        reviewing = true
        reviewGeneration += 1
        let requested = reviewGeneration
        let history = performance.history, data = self.data, mode = self.mode, limit = rolloverLimit
        let completed = progress?.completed ?? []
        let learned = completed.isEmpty ? nil : Course.learnedSkills(completedIDs: completed, data: data, mode: mode)
        reviewButton.title = "Preparing Review…"
        reviewLabel.stringValue = "Building a short review from saved performance…"
        reviewLabel.isHidden = false
        updatePracticeControls()
        DispatchQueue.global(qos: .userInitiated).async {
            let drill = PracticeReview.make(history: history, data: data, mode: mode, rolloverLimit: limit, usable: usable,
                                           day: day, learnedSkills: learned)
            DispatchQueue.main.async { [weak self] in
                guard let self, requested == self.reviewGeneration else { return }
                self.reviewing = false
                self.reviewButton.title = "Review Weak Chords"
                guard let drill else {
                    self.reviewLabel.stringValue = "No review examples match these chords on this keyboard yet."
                    self.updatePracticeControls()
                    return
                }
                self.courseStep = nil
                self.showCourseStep()
                self.setText(drill.text, name: "Personal chord review", planned: drill.guide)
                self.reviewTargets = drill.targets
                self.reviewLabel.stringValue = "Reviewing \(drill.targets.count) \(drill.targets.count == 1 ? "chord" : "chords") in context · due items first"
                self.reviewLabel.isHidden = false
                self.updatePracticeControls()
            }
        }
    }

    /// Opens the course where the learner left off.
    func startCourse() {
        openCourseStep(progress?.resumeIndex ?? 0)
        present()
    }

    /// The optional test-out is always a new exercise with answers hidden from its first chord.
    func startCourseTestOut(presentWindow: Bool = true) {
        let index = progress?.resumeIndex ?? 0
        openCourseStep(index)
        selectLearningStage(.recall)
        if presentWindow { present() }
    }

    func openCourseStep(_ i: Int) {
        guard Course.steps.indices.contains(i) else { return }
        lessonDetailsVisible = false
        courseStage = .see
        demonstrationSteps.removeAll()
        demonstrationIndex = 0
        demonstrationReleased = false
        recallMode = false
        practiceMode.selectedSegment = 0
        startGeneratedExercise(.course(i))
    }

    @objc private func learningStageChanged() {
        guard LearningStage.allCases.indices.contains(learningStages.selectedSegment), courseStep != nil else { return }
        selectLearningStage(LearningStage.allCases[learningStages.selectedSegment])
    }

    private func selectLearningStage(_ stage: LearningStage) {
        guard let index = courseStep else { return }
        pausePracticeTimer()
        courseStage = stage
        recallMode = stage == .recall
        practiceMode.selectedSegment = recallMode ? 1 : 0
        lessonDetailsVisible = false
        hintRevealed = false
        attempt = nil
        if stage == .tryIt || stage == .recall {
            // A stage change never relabels the exercise just seen as unaided recall.
            startGeneratedExercise(.course(index))
        } else {
            onFocus?(false)
            updatePracticeControls()
            refreshKeyboard()
        }
        announce("\(stage.title) stage")
    }

    private func prepareDemonstration(_ guide: TypingGuide) {
        guard let index = courseStep else { return }
        var new = Set(Course.steps[index].new)
        let taught = Course.taught(through: index, data: data)
        for skill in Course.steps[index].new {
            if case .pairs(let bank) = skill {
                new.formUnion(Course.chords(for: skill, data: data, mode: mode).map { Course.Skill.sound(bank, $0.label) }
                    .filter { taught.contains($0) })
            }
        }
        var covered = Set<Course.Skill>()
        var examples: [TypingStep] = []
        for step in guide.steps where step.isChord || step.kind == .key {
            let skills = Course.skills(of: step, data: data, mode: mode)
            let introduced = skills.intersection(new).subtracting(covered)
            if !introduced.isEmpty || (new.contains(.newLine) && step.kind == .key && !examples.contains(where: { $0.action == step.action })) {
                examples.append(step)
                covered.formUnion(introduced)
            }
        }
        for skill in Course.steps[index].new where Course.explainedOnly.contains(skill) {
            for chord in Course.chords(for: skill, data: data, mode: mode) where !chord.keys.isEmpty {
                var command = TypingStep(action: .chord(keys: data.layout.names(chord.keys), shift: chord.shift), kind: .command,
                    output: "", note: chord.label + (chord.note.map { ": " + $0 } ?? ""), source: 0..<0, group: 0)
                command.parts = [.init(text: chord.label, keys: data.layout.names(chord.keys), role: .command)]
                examples.append(command)
            }
        }
        if examples.isEmpty, let first = guide.steps.first { examples = [first] }
        demonstrationSteps = examples
        demonstrationIndex = 0
        demonstrationReleased = false
    }

    @objc private func advanceDemonstration() {
        // A manually stepped model has no autoplay or animated key travel, including with Reduce Motion.
        guard courseStage == .see, !demonstrationSteps.isEmpty else { return }
        if demonstrationReleased {
            demonstrationIndex = (demonstrationIndex + 1) % demonstrationSteps.count
            demonstrationReleased = false
        } else {
            demonstrationReleased = true
        }
        updateLearningStage()
        refreshKeyboard()
        announce(learningDetail.stringValue)
    }

    @objc private func advanceLearningStage() {
        switch courseStage {
        case .see: selectLearningStage(.tryIt)
        case .tryIt, .recall: selectLearningStage(.recall)
        case .use: onUseInEditor?()
        }
    }

    @objc private func continueCourseAfterUse() {
        if let i = courseStep, i + 1 < Course.steps.count, Course.steps[i + 1].mode == mode { openCourseStep(i + 1) }
        else { showCourseOverview() }
    }

    @objc private func startDelayedCheck() { selectLearningStage(.recall) }

    @objc private func showDelayedRules(_ sender: NSButton) {
        pausePracticeTimer()
        if let popover = delayedRulesPopover, popover.isShown { popover.performClose(sender); return }
        let summary = [statsLabel.stringValue, courseStep == nil ? "" : delayedStatus.stringValue].filter { !$0.isEmpty }.joined(separator: "\n")
        let text = (summary.isEmpty ? "" : summary + "\n\n") + "A clean fresh Recall pass schedules a check for tomorrow. Three successful due checks spanning at least four days earn retention. Later checks follow after 3, then 7 days. Same-day repeats add practice.\n\nHints, errors, ordinary typing and paste cannot earn a clean check. Assistance or errors restart the delayed streak. Earlier passes remain saved; changed mappings have their own record. Editor use is a separate self-report. Only aggregate progress is saved."
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 13)
        let content = PracticeUI.surface(label, padding: 16)
        content.widthAnchor.constraint(equalToConstant: 310).isActive = true
        let controller = NSViewController()
        controller.view = content
        let popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = controller
        delayedRulesPopover = popover
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxX)
    }

    private var demonstrationStep: TypingStep? {
        demonstrationSteps.indices.contains(demonstrationIndex) ? demonstrationSteps[demonstrationIndex] : nil
    }

    /// Fingerprint all taught physical mappings and meanings, not the random current exercise.
    /// Changing a taught chord or curriculum cannot reuse a previous delayed-check claim.
    private func lessonMapping(at index: Int) -> UInt64 {
        if let cached = lessonMappingCache[index] { return cached }
        let steps = Course.steps[...index].filter { $0.mode == Course.steps[index].mode }
        var description = "\(Course.curriculumVersion):\(Course.steps[index].mode.rawValue)"
        description += ":\(Course.steps[index].id):\(Course.steps[index].text)"
        for key in data.layout.keys { description += ":\(key.name):\(key.code):\(key.role)" }
        for bank in [Bank.onset, .vowel, .coda] {
            for (keys, sound) in (data.layout.clusters[bank] ?? [:]).sorted(by: { $0.key.bits < $1.key.bits }) {
                description += ":\(bank):\(keys.bits):\(sound)"
            }
        }
        for (keys, letter) in data.layout.fingerspelling.sorted(by: { $0.key.bits < $1.key.bits }) {
            description += ":spell:\(keys.bits):\(letter)"
        }
        for keys in Set(data.dictionary(for: Course.steps[index].mode).entries.keys).union(data.shared.entries.keys)
            .sorted(by: { $0.bits < $1.bits }) {
            let chord = PracticeChord(keys: keys, shift: false, data: data, mode: Course.steps[index].mode)
            description += ":entry:\(keys.bits):\(chord.meaning)"
        }
        for (base, result) in data.orthographyExceptions.sorted(by: { $0.key < $1.key }) {
            description += ":spelling:\(base):\(result)"
        }
        for step in steps {
            for skill in step.new {
                for chord in Course.chords(for: skill, data: data, mode: step.mode) {
                    let meaning = PracticeChord(keys: chord.keys, shift: chord.shift, data: data, mode: step.mode)
                    description += ":\(chord.label):\(meaning.codes):\(meaning.shift):\(meaning.meaning)"
                }
            }
        }
        let fingerprint = DataStore.fnv1a(description)
        lessonMappingCache[index] = fingerprint
        return fingerprint
    }

    private func updateLearningStage() {
        guard learningCard != nil else { return }
        learningCard.isHidden = courseStep == nil
        guard let index = courseStep else {
            demonstrateButton.isHidden = true
            nextExampleButton.isHidden = true
            stageNextButton.isHidden = true
            stageContinueButton.isHidden = true
            delayedCheckButton.isHidden = true
            return
        }
        learningStages.selectedSegment = LearningStage.allCases.firstIndex(of: courseStage) ?? 0
        learningStages.isEnabled = !preparingExercise
        learningTitle.isHidden = true
        demonstrateButton.isHidden = courseStage != .see || demonstrationReleased
        demonstrateButton.isEnabled = demonstrationStep != nil && !preparingExercise
        nextExampleButton.isHidden = courseStage != .see || !demonstrationReleased || demonstrationSteps.count < 2
        stageNextButton.isHidden = courseStage == .tryIt || courseStage == .recall || courseStage == .see && !demonstrationReleased
        stageNextButton.isEnabled = !preparingExercise && (courseStage != .use || onUseInEditor != nil)
        stageContinueButton.isHidden = courseStage != .use
        stageContinueButton.title = index + 1 < Course.steps.count && Course.steps[index + 1].mode == mode ? "Next lesson" : "All lessons"
        let presentation = KeyChordPresentation.lesson(stage: courseStage)
        learningDetail.stringValue = presentation.instruction
        switch courseStage {
        case .see:
            learningTitle.stringValue = "See · physical keys, then release"
            stageNextButton.title = "Try with guide"
            demonstrateButton.title = "Show release"
            if let step = demonstrationStep {
                let keys = physicalCombination(step)
                let output = Self.visible(step.output)
                learningDetail.stringValue = demonstrationReleased ? "All keys are up. \(output.isEmpty ? step.note : "The chord types “" + output + "”.")"
                    : "Hold \(keys) together. The chord waits for every key to release."
            } else {
                learningDetail.stringValue = "Preparing the demonstration. Each chord emits after all its keys are released."
            }
        case .tryIt:
            learningTitle.stringValue = "Try · guided attempt"
            stageNextButton.title = "Start fresh Recall / test out"
        case .recall:
            learningTitle.stringValue = "Recall · fresh unaided exercise"
        case .use:
            learningTitle.stringValue = "Use · a short task in an editor"
            stageNextButton.title = presentation.primaryAction
        }
        let check = progress?.delayedCheck(Course.steps[index].id, mapping: lessonMapping(at: index)) ?? CourseDelayedCheck()
        if check.isRetained {
            delayedStatus.stringValue = "Retained · \(check.successfulDelayedChecks) delayed checks"
        } else if let day = check.nextCheckDay {
            let difference = day.subtractingReportingOverflow(practiceDay())
            let due = difference.overflow ? Int.max : max(0, difference.partialValue)
            delayedStatus.stringValue = "Passed · \(check.successfulDelayedChecks)/3 delayed · "
                + (due == 0 ? "due today" : "next in \(due) \(due == 1 ? "day" : "days")")
        } else {
            delayedStatus.stringValue = "Clean Recall starts delayed checks."
        }
        delayedStatus.toolTip = "Retained: three later successful due checks across at least four days. Same-day repeats do not count. Open How delayed checks earn retention for the full rules."
        delayedCheckButton.isHidden = !check.isDue(day: practiceDay()) || courseStage == .recall
        delayedCheckButton.isEnabled = !preparingExercise
    }

    @objc private func previousStep() {
        if let i = courseStep, i > 0 { openCourseStep(i - 1) }
    }

    @objc private func nextStep() {
        if let i = courseStep, i + 1 < Course.steps.count { openCourseStep(i + 1) }
    }

    /// The card's text for the current step; the keys come from the current layout and dictionaries.
    private func showCourseStep() {
        refreshNavigation()
        guard let i = courseStep else {
            courseCard.isHidden = true
            return
        }
        let step = Course.steps[i]
        let (u, s) = Course.position(of: i)
        let unit = Course.units[u]
        courseCard.isHidden = !lessonDetailsVisible
        coursePosition.stringValue = "\(unit.title) · Lesson \(s + 1) of \(unit.steps.count) · Exercise \(exerciseNumber)"
        courseIntro.stringValue = step.intro
        let chords = step.new.flatMap { Course.introductionChords(for: $0, at: i, data: data) }
        courseNew.isHidden = chords.isEmpty
        let new = NSMutableAttributedString(string: "New in this lesson   ", attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor])
        new.append(ChordText.chords(chords, layout: data.layout, size: 13, meanings: KeyMeanings(data: data, mode: mode)))
        courseNew.attributedStringValue = new
        courseNew.setAccessibilityLabel("New in this step: " + new.string)
        updateCourseState(finished: false)
        // This runs after async generation's setText/refreshProgress. Always reapply stage visibility
        // so fresh Recall cannot briefly reveal the original teaching or new chord mappings.
        updatePracticeControls()
    }

    /// Done mark and buttons; finishing the text marks the step done.
    private func updateCourseState(finished: Bool) {
        guard let i = courseStep else { return }
        let step = Course.steps[i]
        if finished && !wasFinished && qualifiesForChordCredit {
            let clean = courseStage == .recall && !usedAssistance && max(mistakes, scoredMistakes) == 0
            progress?.markDone(step.id, unassisted: clean)
            if courseStage == .recall {
                progress?.recordDelayedCheck(step.id, mapping: lessonMapping(at: i), cleanUnaidedPass: clean, day: practiceDay())
            }
            refreshNavigation()
        }
        wasFinished = finished
        let done = progress?.completed.contains(step.id) ?? finished
        courseTitle.stringValue = (done ? "✓ " : "") + step.title
        updateLearningStage()
    }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        if listening, listeningPractice == nil, !preparingExercise { startListeningPractice() }
        else if isExerciseScreen, text.isEmpty, !preparingExercise, let source = practiceSource { startGeneratedExercise(source) }
        if isExerciseScreen {
            selectPracticeLanguage(mode)
            returnToInput()
        }
        installMonitor()
    }

    /// New dictionaries from Reload Dictionaries (Req 15.6): plan again with them.
    func update(data: EngineData, rolloverLimit: Int) {
        self.data = data
        self.rolloverLimit = rolloverLimit
        mappingVersion += 1
        lessonMappingCache.removeAll()
        exerciseRequest += 1
        preparingExercise = false
        keyboard.layout = data.layout
        updateMeanings()
        showCourseStep()
        if listening { startListeningPractice() }
        else if text.isEmpty, let source = practiceSource { startGeneratedExercise(source) }
        else { replan(preservingInput: importedText) }
    }

    // MARK: Focus and keys

    @objc private func toggleFullscreen() {
        window?.toggleFullScreen(nil)
        returnToInput()
    }

    func window(_ window: NSWindow, willUseFullScreenContentSize proposedSize: NSSize) -> NSSize {
        // AppKit can infer a narrow fullscreen size from a compact child view.
        // Use the display's width while preserving its proposed height and safe area.
        NSSize(width: window.screen?.frame.width ?? proposedSize.width, height: proposedSize.height)
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        returnToInput()
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        returnToInput()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        promptBeganAt = ProcessInfo.processInfo.systemUptime
        onFocus?(isExerciseScreen)
        if isExerciseScreen {
            selectPracticeLanguage(mode)
            if !hasError { onSyncContext?(promptContext) }
            if listeningPractice?.isComplete != true { replayWord() }
            resumePracticeTimer()
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        pausePracticeTimer()
        speaker.stop()
        onFocus?(false)
        held.removeAll()
        chordCodes.removeAll()
        attempt = nil
        refreshKeyboard()
    }

    func windowWillClose(_ notification: Notification) {
        pausePracticeTimer()
        speaker.stop()
        onFocus?(false)
        exerciseRequest += 1
        preparingExercise = false
        attempt = nil
        clearReview()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// Without the event tap (no permission yet), key presses still reach the window in Normal mode.
    private func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] e in
            guard let self, let w = self.window, w.isKeyWindow else { return e }
            if e.type == .keyDown, e.keyCode == 3, e.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.command, .control] {
                self.toggleFullscreen()
                return nil
            }
            if e.type == .keyDown, !e.isARepeat, self.isExerciseScreen,
               e.modifierFlags.intersection([.command, .shift, .control, .option]) == [.command, .shift] {
                if e.keyCode == 4, self.recallMode || self.listening {
                    self.revealHint()
                    return nil
                }
                if e.keyCode == 15, self.listening {
                    self.replayWord()
                    return nil
                }
            }
            guard !self.tapIsRunning() else { return e }
            if let cg = e.cgEvent, OutputEmitter.isSynthetic(cg) { return e }
            switch e.type {
            case .keyDown where !e.isARepeat: self.rawKey(.down(e.keyCode))
            case .keyUp: self.rawKey(.up(e.keyCode))
            case .flagsChanged:
                if let (_, down) = EventConversion.modifierChange(code: e.keyCode, flags: UInt64(e.modifierFlags.rawValue)) {
                    self.rawKey(down ? .down(e.keyCode) : .up(e.keyCode))
                }
            default: break
            }
            return e
        }
    }

    func rawKey(_ e: RawKeyEvent) {
        switch e {
        case .down(let c):
            held.insert(c)
            if [54, 55, 58, 59, 61, 62, 63].contains(c) { attempt = nil }
            if !Self.modifierCodes.contains(c) {
                if chordCodes.isEmpty {
                    chordShift = held.contains(56) || held.contains(60)
                    beginAttempt(code: c)
                }
                chordCodes.insert(c)
            }
            if c == 56 || c == 60 { chordShift = true }
        case .up(let c):
            held.remove(c)
            if held.subtracting(Self.modifierCodes).isEmpty && !chordCodes.isEmpty {
                let chord = chordCodes
                chordCodes.removeAll()
                finishAttempt(codes: chord)
                chordReleased(chord)
            }
        }
        refreshKeyboard()
    }

    private func beginAttempt(code: KeyCode) {
        attempt = nil
        guard inputIsFocused,
              courseStep == nil || (courseStage != .see && courseStage != .use),
              typingMode == mode, !hasError, data.layout.indexByCode[code] != nil,
              held.isDisjoint(with: [54, 55, 58, 59, 61, 62, 63]),
              let g = active, let i = currentStep, i < g.steps.count,
              let target = PracticeChord(step: g.steps[i], data: data, mode: mode) else { return }
        if startTime == nil { startTime = Date() }
        resumePracticeTimer()
        attempt = Attempt(step: g.steps[i], target: target, context: promptContext, beganAt: promptBeganAt,
                          assisted: visibleAssistance)
    }

    private func finishAttempt(codes: Set<KeyCode>) {
        guard let captured = attempt else { return }
        attempt = nil
        guard typingMode == mode, inputIsFocused else { return }
        capturedChordAttempts += 1
        usedAssistance = usedAssistance || captured.assisted
        let correct = PracticeAssessment.matches(captured.step, codes: codes, shift: chordShift,
                                                capsLock: NSEvent.modifierFlags.contains(.capsLock),
                                                context: captured.context, data: data, mode: mode)
        let indices = codes.compactMap { data.layout.indexByCode[$0] }
        let chord = correct ? PracticeChord(keys: KeySet(indices), shift: chordShift, data: data, mode: mode) : captured.target
        performance.record(chord, correct: correct, seconds: ProcessInfo.processInfo.systemUptime - captured.beganAt,
                           hinted: captured.assisted)
        if !correct {
            scoredMistakes += 1
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastAnnouncedErrorAt >= 3 {
                lastAnnouncedErrorAt = now
                announce("That chord differs from the target. Release all keys and try again.")
            }
        }
        promptBeganAt = ProcessInfo.processInfo.systemUptime
        updateStats(finished: finishTime != nil)
        updatePracticeControls()
    }

    /// Steps that type nothing visible are confirmed by their chord, since the text cannot show them.
    private func chordReleased(_ chord: Set<KeyCode>) {
        guard typingMode == mode, window?.firstResponder === inputView else { return }
        guard let guide = active, let i = currentStep, i < guide.steps.count else { return }
        let step = guide.steps[i]
        guard Self.needsConfirmation(step) || step.kind == .cancelCapital else { return }
        if targetCodes(step).subtracting(Self.modifierCodes) == chord {
            doneSteps.insert(i)
            refreshProgress()
        }
    }

    private static func needsConfirmation(_ s: TypingStep) -> Bool {
        s.kind == .command || s.action == .key(.delete)
    }

    // MARK: Import, mode, restart

    @objc private func importFile() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .sourceCode]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a text file to practice with KeyChord."
        panel.prompt = "Import"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.load(url)
        }
    }

    private func load(_ url: URL) {
        do {
            let size = (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size <= Self.maxFileBytes else {
                showError("This file is too large", "The Typing Guide handles text files up to 1 MB.")
                return
            }
            var encoding = String.Encoding.utf8
            let s: String
            if let utf8 = try? String(contentsOf: url, encoding: .utf8) {
                s = utf8
            } else {
                s = try String(contentsOf: url, usedEncoding: &encoding)
            }
            importText(s, name: url.lastPathComponent)
        } catch {
            showError("Could not read the file", error.localizedDescription)
        }
    }

    /// Shared by file import and the disposable AppKit harness. Passage and draft remain memory-only.
    func importText(_ source: String, name: String? = nil) {
        exerciseRequest += 1
        stopListeningPractice()
        preparingExercise = false
        practiceSource = nil
        courseStep = nil
        importedText = true
        importedFileName = name
        importLanguageSelection = 0
        importLanguagePopup.selectItem(at: 0)
        showCourseStep()
        setText(source, name: name)
        importLanguagePopup.item(at: 0)?.title = "Auto (\(mode == .english ? "English" : "C++"))"
        showExercise()
    }

    @objc private func importLanguageChanged() {
        guard importedText, (0...2).contains(importLanguagePopup.indexOfSelectedItem) else { return }
        importLanguageSelection = importLanguagePopup.indexOfSelectedItem
        let detected = PracticeLanguage.detect(text, fileName: importedFileName)
        let selected: SubMode = importLanguageSelection == 0 ? detected : importLanguageSelection == 1 ? .english : .cpp
        guard mode != selected else { return }
        pausePracticeTimer()
        selectPracticeLanguage(selected)
        applyTextSize()
        replan(preservingInput: true)
        announce("Imported text uses \(selected == .english ? "English" : "C++"). Draft preserved.")
    }

    private func setText(_ s: String, name: String?, language: SubMode? = nil, planned: TypingGuide? = nil) {
        selectPracticeLanguage(language ?? planned?.mode ?? PracticeLanguage.detect(s, fileName: name))
        clearReview()
        inputView.isEditable = true
        // Return types "\n", so line breaks are compared as "\n".
        text = String(s.map { $0 == "\r\n" || $0 == "\r" ? "\n" : $0 })
        chars = Array(text)
        targetUTF16 = Array(text.utf16)
        var offsets = [0]
        offsets.reserveCapacity(chars.count + 1)
        var ends: [Int] = []
        var u = 0
        for (i, c) in chars.enumerated() {
            u += c.utf16.count
            offsets.append(u)
            if !c.isWhitespace && (i + 1 == chars.count || chars[i + 1].isWhitespace) { ends.append(i + 1) }
        }
        utf16Offsets = offsets
        wordEnds = ends
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 8
        passageView.textStorage?.setAttributedString(NSAttributedString(string: listening ? "" : text, attributes: [
            .font: mode == .cpp ? NSFont.monospacedSystemFont(ofSize: CGFloat(practiceSettings.practiceTextSize), weight: .regular)
                               : NSFont.systemFont(ofSize: CGFloat(practiceSettings.practiceTextSize)),
            .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: para,
        ]))
        applyTextSize()
        styled = (0, 0, NSRange(location: 0, length: 0))
        window?.title = "KeyChord Typing Practice" + (name.map { ": \($0)" } ?? "")
        pageTitle.stringValue = courseStep.map { Course.steps[$0].title } ?? (name ?? "Practice")
        DispatchQueue.main.async { [weak self] in self?.fitPassage() }
        if let planned {
            generation += 1
            guide = planned
            active = planned
            setContinuation(nil)
            continuationPlanner = nil
            clearInput()
            refreshProgress()
        } else {
            replan()
        }
    }

    /// Opens a practice text (from the Course menu or a link in the manual) in its mode.
    func practice(_ lesson: Lesson) {
        load(lesson)
        present()
    }

    /// Opens a fresh exercise for built-in topics, while external lessons keep their supplied text.
    func load(_ lesson: Lesson) {
        importedText = false
        if let index = Lessons.all.firstIndex(of: lesson) {
            startGeneratedExercise(.topic(index))
            return
        }
        exerciseRequest += 1
        stopListeningPractice()
        practiceSource = nil
        courseStep = nil
        showCourseStep()
        setText(lesson.text, name: lesson.title, language: lesson.mode)
        showExercise()
    }

    @objc private func restart() {
        if let index = courseStep, courseStage == .recall {
            // The learner may have seen an answer before retrying. Recall always gets another exercise;
            // lesson details remain visible if chosen and therefore remain classified as assistance.
            startGeneratedExercise(.course(index))
            return
        }
        if listening {
            if listeningPractice?.isComplete == true { nextListeningWord(); return }
            clearInput()
            refreshProgress()
            replayWord()
            return
        }
        clearInput()
        refreshProgress()
    }

    private func clearInput() {
        inputView.string = ""
        inputOrigins.removeAll()
        capturedChordAttempts = 0
        emittedChordOutputs = 0
        usedAssistance = false
        activePracticeSeconds = 0
        activePracticeSince = nil
        inputView.undoManager?.removeAllActions()
        editFloor = 0
        startTime = nil
        finishTime = nil
        mistakes = 0
        scoredMistakes = 0
        announcedCompletion = false
        attempt = nil
        displayedStep = nil
        hintRevealed = false
        listeningWordRevealed = false
        usedAssistance = visibleAssistance
        promptBeganAt = ProcessInfo.processInfo.systemUptime
        doneSteps.removeAll()
        currentGroup = nil
        lastTypedLen = 0
        onResetContext?()
        onSyncContext?(.initial)
        if isExerciseScreen { window?.makeFirstResponder(inputView) }
    }

    /// Plans off the main thread; a newer request supersedes older ones.
    private func replan(preservingInput: Bool = false) {
        clearReview()
        generation += 1
        let gen = generation
        let text = self.text, data = self.data, mode = self.mode, limit = rolloverLimit
        let usable = limits.map { $0.usable(in: data.layout) } ?? { _ in true }
        guide = nil
        active = nil
        setContinuation(nil)
        continuationPlanner = nil
        if preservingInput {
            attempt = nil
            displayedStep = nil
            doneSteps.removeAll()
            currentGroup = nil
            editFloor = 0
        } else { clearInput() }
        refreshProgress()
        DispatchQueue.global(qos: .userInitiated).async {
            let planned = TypingPlanner(data: data, mode: mode, rolloverLimit: limit, usable: usable).plan(text)
            DispatchQueue.main.async { [weak self] in
                guard let self, gen == self.generation else { return }
                self.guide = planned
                self.editFloor = 0
                self.refreshProgress()
                if preservingInput && !self.hasError { self.onSyncContext?(self.promptContext) }
            }
        }
    }

    private func showError(_ title: String, _ message: String) {
        announce(title + ". " + message)
        guard let window else { return }
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.addButton(withTitle: "OK")
        a.beginSheetModal(for: window)
    }

    private func announce(_ message: String) {
        guard !message.isEmpty else { return }
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
            userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }

    // MARK: Typing progress

    func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
        editFloor = min(editFloor, range.location)
        guard let replacement = replacementString else {
            inputOrigins = Array(repeating: .ordinary, count: inputView.string.utf16.count)
            return true
        }
        // Unobserved edits/undo are conservatively ordinary input.
        if inputOrigins.count != inputView.string.utf16.count {
            inputOrigins = Array(repeating: .ordinary, count: inputView.string.utf16.count)
        }
        if range.location <= inputOrigins.count, NSMaxRange(range) <= inputOrigins.count {
            var origin: InputOrigin = applyingChordOutput && typingMode == mode ? .chord(mode, mappingVersion) : .ordinary
            if !applyingChordOutput, typingMode == mode,
               (inputView as? PracticeInputView)?.structuralInput == replacement,
               let step = displayedStep {
                switch step.action {
                case .key(.returnKey) where replacement == "\n", .key(.tab) where replacement == "\t":
                    origin = .structural(mode, mappingVersion)
                default: break
                }
            }
            inputOrigins.replaceSubrange(range.location..<NSMaxRange(range),
                with: repeatElement(origin, count: replacement.utf16.count))
        }
        return true
    }

    func textDidChange(_ notification: Notification) {
        guard !applyingChordOutput else { return }
        refreshProgress()
    }

    /// Keep a chord's edits together in the practice field. A spelling-changing suffix deletes before
    /// it inserts; observing the temporary deletion would replan and reset the engine between those edits.
    /// Queue outside the event-tap callback, in the same order as the raw key notifications.
    func receiveOutput(_ actions: [OutputAction]) -> Bool {
        guard courseStep == nil || (courseStage != .see && courseStage != .use) else { return false }
        guard isExerciseScreen, window?.isKeyWindow == true, window?.firstResponder === inputView else { return false }
        DispatchQueue.main.async { [weak self] in self?.applyChordOutput(actions) }
        return true
    }

    func applyChordOutput(_ actions: [OutputAction]) {
        guard courseStep == nil || (courseStage != .see && courseStage != .use) else { return }
        if typingMode == mode, actions.contains(where: { if case .insert(let text) = $0 { return !text.isEmpty }; return false }) {
            emittedChordOutputs += 1
            usedAssistance = usedAssistance || visibleAssistance
            if startTime == nil { startTime = Date() }
            resumePracticeTimer()
        }
        applyingChordOutput = true
        inputView.undoManager?.beginUndoGrouping()
        for action in actions {
            switch action {
            case .insert(let text): inputView.insertText(text, replacementRange: inputView.selectedRange())
            case .deleteBackward(let count): for _ in 0..<count { inputView.deleteBackward(nil) }
            case .deleteForward(let count): for _ in 0..<count { inputView.deleteForward(nil) }
            case .moveLeft(let count): for _ in 0..<count { inputView.moveLeft(nil) }
            case .moveRight(let count): for _ in 0..<count { inputView.moveRight(nil) }
            }
        }
        inputView.undoManager?.endUndoGrouping()
        applyingChordOutput = false
        textDidChange(Notification(name: NSText.didChangeNotification, object: inputView))
    }

    var qualifiesForChordCredit: Bool {
        capturedChordAttempts > 0 && emittedChordOutputs > 0
            && inputOrigins.count == inputView.string.utf16.count
            && !inputOrigins.isEmpty && inputOrigins.allSatisfy {
                switch $0 {
                case .chord(let originMode, let version), .structural(let originMode, let version):
                    return originMode == mode && version == mappingVersion
                case .ordinary: return false
                }
            }
    }

    private func pausePracticeTimer() {
        if let began = activePracticeSince { activePracticeSeconds += Date().timeIntervalSince(began) }
        activePracticeSince = nil
    }

    private func resumePracticeTimer() {
        guard startTime != nil, finishTime == nil, activePracticeSince == nil,
              typingMode == mode, isExerciseScreen, settingsPopover?.isShown != true,
              delayedRulesPopover?.isShown != true,
              inputIsFocused else { return }
        activePracticeSince = Date()
    }

    /// Compares the typed text with the passage and updates the colors, current word, hint, and keyboard.
    private func refreshProgress() {
        let typed: NSString = inputView.textStorage?.mutableString ?? ""
        let typedLen = typed.length
        // Text before the lowest edit is unchanged, so the comparison can resume there.
        var i = max(0, min(correctUTF16, editFloor, typedLen, targetUTF16.count))
        editFloor = Int.max
        while i < typedLen && i < targetUTF16.count && typed.character(at: i) == targetUTF16[i] { i += 1 }
        correct = charIndex(forUTF16: i)
        correctUTF16 = utf16Offsets[correct]

        let wasError = hasError
        hasError = typedLen > correctUTF16
        let deleted = typedLen < lastTypedLen
        lastTypedLen = typedLen

        // The plan to follow: a continuation covers its stretch of the line, the whole-passage plan the rest.
        // Leaving a continuation at its end puts KeyChord's context back where the whole-passage plan has it.
        if let c = continuation, !(correct >= c.start && correct < c.end) {
            setContinuation(nil)
            if correct == c.end, let g = guide, let ctx = contextEnding(at: correct, in: g) { onSyncContext?(ctx) }
        }
        active = continuation?.guide ?? guide

        // A planned in-between state is not a mistake: the base of a suffix whose spelling changes
        // ("make" before + ing) or a throwaway letter before Delete.
        let tailStep = hasError ? plannedTailStep(typed) : nil
        if tailStep != nil { hasError = false }
        let finished = !chars.isEmpty && correct == chars.count && !hasError
        if finished && finishTime == nil { finishTime = Date() }
        if finished { pausePracticeTimer() }
        if !finished { finishTime = nil }

        // Typed text the plan does not pass through, such as part of a word and then Delete: work out the
        // chords for the rest from here.
        if !hasError && !finished, let g = active,
           !g.isPlanned(at: correct, tailStep: tailStep, start: continuation?.start ?? 0) { startContinuation() }

        // Current step: the first one of the word at the cursor not yet done.
        currentStep = nil
        var wordRange = NSRange(location: correctUTF16, length: 0)
        if let guide = active, !finished, let first = guide.stepIndex(at: correct) {
            let group = guide.steps[first].group
            if group != currentGroup {
                currentGroup = group
                doneSteps.removeAll()
            }
            var end = first
            while end < guide.steps.count && guide.steps[end].group == group { end += 1 }
            var j = first
            if let t = tailStep {
                j = t + 1
                while j < end && doneSteps.contains(j) { j += 1 }
            } else {
                while j < end {
                    let s = guide.steps[j]
                    if doneSteps.contains(j) { j += 1; continue }
                    if s.textEnd > correct || (s.textEnd == correct && Self.needsConfirmation(s)) { break }
                    j += 1
                }
            }
            currentStep = min(j, guide.steps.count - 1)
            let lo = guide.steps[first..<end].map(\.source.lowerBound).min() ?? correct
            let hi = guide.steps[first..<end].map(\.source.upperBound).max() ?? correct
            wordRange = nsRange(lo..<hi)
        }
        let showError = hasError
        if showError && !wasError {
            mistakes += 1
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastAnnouncedErrorAt >= 3 {
                lastAnnouncedErrorAt = now
                announce("Text differs from the target. Delete the mistake and try again.")
            }
        }
        if wasError && !hasError, let guide = active {
            // A fixed mistake may have used up a command (such as Capitalize_Next): ask for it again.
            doneSteps = doneSteps.filter { guide.steps[$0].kind != .command }
        }
        if (deleted || (wasError && !hasError)) && !hasError, let guide = active, let cur = currentStep {
            // Delete resets KeyChord's context; put it back where the plan is, so the next chord gets its
            // leading space and capital as planned.
            var j = cur - 1
            while j >= 0 && guide.steps[j].group == guide.steps[cur].group && !doneSteps.contains(j)
                    && Self.needsConfirmation(guide.steps[j]) { j -= 1 }
            if j < 0 {
                if let c = continuation {
                    if correct == c.start { onSyncContext?(c.startContext) }
                } else if typedLen == 0 {
                    onSyncContext?(.initial)
                }
            } else if let ctx = guide.steps[j].contextAfter, typedMatches(step: guide.steps[j], typed) {
                onSyncContext?(ctx)
            }
        }

        let nextPrompt = currentStep.flatMap { i in active.flatMap { i < $0.steps.count ? $0.steps[i] : nil } }
        if nextPrompt != displayedStep {
            displayedStep = nextPrompt
            if !listening { hintRevealed = false }
            promptBeganAt = ProcessInfo.processInfo.systemUptime
        }
        restylePassage(typedEnd: hasError ? min(typedLen, targetUTF16.count) : correctUTF16, word: wordRange,
                       scroll: wordRange != styled.word)
        updateWordPanel(finished: finished, showError: showError)
        updateCourseState(finished: finished)
        updateStats(finished: finished)
        completionCard.isHidden = !finished || (listening && listeningPractice?.isSessionComplete != true)
        if listening, finished, qualifiesForChordCredit, let session = listeningPractice, session.check(inputView.string) {
            speaker.stop()
            inputView.isEditable = false
            listeningStatus.stringValue = "Correct. Choose Next word when you're ready."
            updateListeningCount()
            if session.isSessionComplete { finishListeningSession(session) }
        }
        if finished && !(listeningPractice?.isSessionComplete == true) {
            let cleanCoursePass = courseStep != nil && courseStage == .recall && !usedAssistance && max(mistakes, scoredMistakes) == 0
            completionTitle.stringValue = qualifiesForChordCredit
                ? (courseStep != nil && courseStage == .recall
                    ? (cleanCoursePass ? "Fresh Recall passed" : "Recall practice complete; retry for a clean pass")
                    : (usedAssistance ? "Guided practice complete" : "Unassisted practice complete")) : "Text matched"
            completionDetail.stringValue = qualifiesForChordCredit ? statsLabel.stringValue
                : "Ordinary typing or pasted text is available for editing. Restart and use chords to earn practice credit."
            if cleanCoursePass { completionDetail.stringValue += ". " + delayedStatus.stringValue }
            if listening && !qualifiesForChordCredit {
                listeningStatus.stringValue = "Text matched without chord credit. Retry this word with chords."
            }
            if courseStep != nil && qualifiesForChordCredit {
                completionNext.title = cleanCoursePass ? "Continue to Use" : "Start fresh Recall"
            } else if qualifiesForChordCredit && usedAssistance {
                completionNext.title = "Try without hints"
            } else if let index = courseStep, index + 1 < Course.steps.count, Course.steps[index + 1].mode == mode {
                completionNext.title = "Continue to next lesson"
            } else {
                completionNext.title = practiceSource != nil || !reviewTargets.isEmpty ? "Practice another exercise" : "Choose another skill"
            }
        }
        updatePracticeControls()
        refreshKeyboard()
        if finished && !announcedCompletion {
            announcedCompletion = true
            announce(completionTitle.stringValue + ". " + completionDetail.stringValue)
        } else if !finished { announcedCompletion = false }
    }

    /// Whether the typed text is exactly the planned text after `step`.
    private func typedMatches(step: TypingStep, _ typed: NSString) -> Bool {
        let p = step.prefixEnd
        guard p >= 0, p <= correct, p < utf16Offsets.count else { return false }
        let tail = step.tail as NSString
        let start = utf16Offsets[p]
        guard typed.length == start + tail.length else { return false }
        return tail.length == 0 || typed.substring(from: start) == step.tail
    }

    /// The planned context after the last step that ends exactly at `offset`.
    private func contextEnding(at offset: Int, in g: TypingGuide) -> EngineContext? {
        guard let first = g.stepIndex(at: offset) else { return g.steps.last?.contextAfter }
        var k = min(g.steps.count - 1, first + 1)
        while k >= 0 && g.steps[k].textEnd >= offset {
            if g.steps[k].textEnd == offset && g.steps[k].tail.isEmpty { return g.steps[k].contextAfter }
            k -= 1
        }
        return k >= 0 && g.steps[k].textEnd == offset ? g.steps[k].contextAfter : nil
    }

    /// The planned context at the last step boundary at or before `offset`.
    private func contextBefore(_ offset: Int, in g: TypingGuide) -> EngineContext? {
        var k = min(g.steps.count - 1, (g.stepIndex(at: offset) ?? g.steps.count - 1) + 1)
        while k >= 0 {
            let s = g.steps[k]
            if s.textEnd <= offset && s.tail.isEmpty { return s.contextAfter }
            k -= 1
        }
        return nil
    }

    private func setContinuation(_ c: TypingContinuation?) {
        continuation = c
        currentGroup = nil
        doneSteps.removeAll()
    }

    /// Plans the rest of the line from the cursor and puts KeyChord's context where that plan starts.
    private func startContinuation() {
        guard let g = guide else { return }
        if continuationPlanner == nil {
            let usable = limits.map { $0.usable(in: data.layout) } ?? { _ in true }
            continuationPlanner = TypingPlanner(data: data, mode: mode, rolloverLimit: rolloverLimit, usable: usable)
        }
        let previous = (active.flatMap { contextBefore(correct, in: $0) }) ?? continuation?.startContext
            ?? contextBefore(correct, in: g)
        guard let c = continuationPlanner?.planContinuation(chars, from: correct, previous: previous),
              !c.guide.steps.isEmpty else { return }
        setContinuation(c)
        active = c.guide
        onSyncContext?(c.startContext)
    }

    /// The step whose planned in-between text (with a tail) is what has been typed, if any.
    private func plannedTailStep(_ typed: NSString) -> Int? {
        guard let guide = active, let first = guide.stepIndex(at: correct) else { return nil }
        let g = guide.steps[first].group
        var end = first
        while end < guide.steps.count && guide.steps[end].group == g { end += 1 }
        for j in stride(from: end - 1, through: max(0, first - 1), by: -1) {
            let s = guide.steps[j]
            if !s.tail.isEmpty && typedMatches(step: s, typed) { return j }
        }
        return nil
    }

    private func restylePassage(typedEnd: Int, word: NSRange, scroll: Bool) {
        guard let storage = passageView.textStorage, storage.length == targetUTF16.count else { return }
        let old = styled
        styled = (correctUTF16, max(typedEnd, correctUTF16), word)
        // Only the part that changed is restyled, so long texts stay fast.
        let lo = min(old.correct, correctUTF16, old.word.location, word.location)
        let hi = max(old.typedEnd, styled.typedEnd, NSMaxRange(old.word), NSMaxRange(word), old.correct, correctUTF16)
        let dirty = NSRange(location: lo, length: min(hi, storage.length) - lo)
        guard dirty.length > 0 || scroll else { return }
        func apply(_ r: NSRange, _ attrs: [NSAttributedString.Key: Any]) {
            let x = NSIntersectionRange(r, dirty)
            if x.length > 0 { storage.addAttributes(attrs, range: x) }
        }
        storage.beginEditing()
        storage.removeAttribute(.backgroundColor, range: dirty)
        storage.removeAttribute(.underlineStyle, range: dirty)
        storage.removeAttribute(.strikethroughStyle, range: dirty)
        storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: dirty)
        apply(word, [.foregroundColor: NSColor.labelColor, .underlineStyle: NSUnderlineStyle.thick.rawValue,
                     .underlineColor: NSColor.controlAccentColor])
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        apply(NSRange(location: 0, length: correctUTF16), [.foregroundColor: contrast ? NSColor.labelColor : NSColor.systemGreen,
                                                        .underlineStyle: NSUnderlineStyle.single.rawValue])
        apply(NSRange(location: correctUTF16, length: styled.typedEnd - correctUTF16),
              [.foregroundColor: NSColor.labelColor,
               .backgroundColor: contrast ? NSColor.unemphasizedSelectedTextBackgroundColor : NSColor.systemRed.withAlphaComponent(0.35),
               .underlineStyle: NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue])
        storage.endEditing()
        if scroll { passageView.scrollRangeToVisible(word) }
    }

    private func updateWordPanel(finished: Bool, showError: Bool) {
        partsLabel.stringValue = ""
        if listening && (answersHidden || text.isEmpty) {
            wordLabel.stringValue = listeningWordRevealed ? text : ""
            comboLabel.stringValue = ""
            comboLabel.setAccessibilityValue("")
            hintLabel.stringValue = showError ? "Not quite. Delete the mistake and try again, or press ⌘⇧H for the answer." : ""
            hintLabel.textColor = .systemRed
            return
        }
        guard let guide = active else {
            wordLabel.stringValue = chars.isEmpty ? "" : "…"
            comboLabel.stringValue = chars.isEmpty ? "" : "working out the chords"
            hintLabel.stringValue = chars.isEmpty ? "Import a text file to practice with." : ""
            return
        }
        if finished {
            wordLabel.stringValue = "Done"
            comboLabel.attributedStringValue = NSAttributedString(string: "")
            hintLabel.stringValue = ""
            return
        }
        guard let cur = currentStep else {
            wordLabel.stringValue = ""
            comboLabel.stringValue = ""
            hintLabel.stringValue = guide.steps.isEmpty ? "The text is empty." : ""
            return
        }
        let group = guide.steps[cur].group
        var first = cur, end = cur
        while first > 0 && guide.steps[first - 1].group == group { first -= 1 }
        while end < guide.steps.count && guide.steps[end].group == group { end += 1 }
        let src = guide.steps[first].source
        // In the middle of a word, the part already typed is shown in green before what is left.
        var wordStart = src.lowerBound
        if wordStart < chars.count, TypingPlanner.isWordChar(chars[wordStart]) {
            while wordStart > 0 && TypingPlanner.isWordChar(chars[wordStart - 1]) { wordStart -= 1 }
        }
        let wordFont = NSFont.systemFont(ofSize: 28, weight: .semibold)
        let word = NSMutableAttributedString()
        if wordStart < src.lowerBound {
            word.append(NSAttributedString(string: sourceText(wordStart..<src.lowerBound),
                                           attributes: [.font: wordFont, .foregroundColor: NSColor.systemGreen]))
        }
        word.append(NSAttributedString(string: Self.visible(sourceText(src)),
                                       attributes: [.font: wordFont, .foregroundColor: NSColor.labelColor]))
        wordLabel.attributedStringValue = word
        if listening { wordLabel.stringValue = text }
        if !answersHidden { partsLabel.attributedStringValue = partsText(guide.steps[cur]) }

        if answersHidden && !showError {
            comboLabel.attributedStringValue = NSAttributedString(string: "")
            comboLabel.setAccessibilityValue("")
            hintLabel.stringValue = "Recall the next chord. Show Hint (⌘⇧H) reveals its keys."
            hintLabel.textColor = .secondaryLabelColor
            return
        }

        let combo = NSMutableAttributedString()
        let font = NSFont.monospacedSystemFont(ofSize: 18, weight: .medium)
        let answerGuide = listening ? (self.guide ?? guide) : guide
        let answerCursor = listening ? (answerGuide.steps.firstIndex { $0.textEnd > correct } ?? answerGuide.steps.count) : cur
        let shownSteps = listening ? answerGuide.steps.indices : cur..<(cur + 1)
        for j in shownSteps {
            if j > shownSteps.lowerBound {
                combo.append(NSAttributedString(string: "  ›  ", attributes: [.font: font, .foregroundColor: NSColor.tertiaryLabelColor]))
            }
            let color: NSColor = j < answerCursor ? .tertiaryLabelColor : j == answerCursor ? (showError ? .systemRed : .controlAccentColor) : .labelColor
            let weight: NSFont.Weight = j == answerCursor ? .bold : .medium
            combo.append(NSAttributedString(string: combination(orderedAction(answerGuide.steps[j])), attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 18, weight: weight), .foregroundColor: color,
            ]))
        }
        comboLabel.attributedStringValue = combo
        comboLabel.setAccessibilityValue(combo.string)

        if showError {
            var fix = "Not quite. Fix it with ⌫ Delete"
            if let undo = undoCombination() { fix += " or the undo chord \(undo)" }
            hintLabel.stringValue = fix + "."
            hintLabel.textColor = .systemRed
            return
        }
        hintLabel.textColor = .secondaryLabelColor
        let step = guide.steps[cur]
        switch step.action {
        case .chord(_, let shift) where shift:
            hintLabel.stringValue = "Hold ⇧ Shift with this chord to join it to the word before "
                + "(the keyboard can't take the space bar with these keys)."
        case .chord where step.parts.contains { $0.role == .join }:
            hintLabel.stringValue = "Hold the space bar with this chord to join it to the word before."
        case .typeNormally:
            hintLabel.stringValue = "No chord for this: tap right ⌥ Option, type it normally, tap right ⌥ Option again."
        default:
            hintLabel.stringValue = step.kind == .command || step.kind == .cancelCapital || step.kind == .key ? step.note : ""
        }
    }

    private func updateStats(finished: Bool) {
        let done = upperBound(wordEnds, correct)
        var s = "\(done)/\(wordEnds.count) words"
        if finished, qualifiesForChordCredit, !usedAssistance, startTime != nil {
            let seconds = activePracticeSeconds + (activePracticeSince.map { Date().timeIntervalSince($0) } ?? 0)
            let minutes = max(seconds / 60, 1.0 / 60)
            s += String(format: "  ·  %.0f chord wpm", Double(correct) / 5 / minutes)
        }
        let totalMistakes = max(mistakes, scoredMistakes)
        s += "  ·  \(totalMistakes) \(totalMistakes == 1 ? "mistake" : "mistakes")"
        if finished { s = (qualifiesForChordCredit ? (usedAssistance ? "Guided · " : "Unassisted · ") : "Text matched · ") + s }
        statsLabel.stringValue = s
        sessionProgress.doubleValue = chars.isEmpty ? 0 : Double(correct) / Double(chars.count)
    }

    private func refreshKeyboard() {
        var target = Set<KeyCode>()
        var caption = ""
        let isDemonstration = courseStep != nil && courseStage == .see
        if isDemonstration, let step = demonstrationStep {
            target = targetCodes(step)
            caption = demonstrationReleased ? "Demonstration: all keys released" : "Demonstration: press all target keys together"
        } else if let guide = active, let cur = currentStep, cur < guide.steps.count {
            let step = guide.steps[cur]
            if hasError {
                target = [51]
                caption = "Press Delete"
            } else if answersHidden {
                caption = "Chord keys hidden"
            } else {
                target = targetCodes(step)
                caption = "Press " + combination(orderedAction(step))
            }
        }
        let modelHeld = target.contains(56) && target.contains(60) ? target.subtracting([60]) : target
        let shownHeld = isDemonstration ? (demonstrationReleased ? Set<KeyCode>() : modelHeld) : held
        keyboard.target = target
        keyboard.held = shownHeld
        let heldNames = shownHeld.sorted().map { KeyboardDiagramView.physicalName(for: $0) }
        let targetNames = target.sorted().filter { ![56, 60].contains($0) }.map { KeyboardDiagramView.physicalName(for: $0) }
        let shift = target.contains(56) || target.contains(60) ? ["Shift (either left or right)"] : []
        targetStateLabel.stringValue = caption + (target.isEmpty ? "" : ": " + (targetNames + shift).joined(separator: " + "))
            + ". Held: " + (heldNames.isEmpty ? "none" : heldNames.joined(separator: " + "))
        if !answersHidden && !hasError && !target.isEmpty { targetStateLabel.stringValue += ". Release every key to emit." }
        keyboard.setAccessibilityLabel(caption + ". Held: " + (heldNames.isEmpty ? "none" : heldNames.joined(separator: " + ")))
        keyboardText.update(layout: data.layout, meanings: answersHidden ? nil : keyMeanings, target: target, held: shownHeld)
    }

    // MARK: Step formatting

    private static func partRoleName(_ role: TypingStep.Part.Role) -> String {
        switch role {
        case .onset: return "Start"
        case .vowel: return "Vowel"
        case .coda: return "End"
        case .word: return "Word"
        case .spell: return "Spelling"
        case .capital: return "Capital"
        case .letter: return "Letter"
        case .digit: return "Number"
        case .suffix: return "Ending"
        case .symbol: return "Punctuation"
        case .space: return "Space"
        case .command: return "Action"
        case .join: return "Join"
        }
    }

    private func physicalCombination(_ step: TypingStep) -> String {
        let keys = targetCodes(step).sorted().filter { ![56, 60].contains($0) }
            .map { KeyboardDiagramView.physicalName(for: $0) }
        if case .chord(_, true) = step.action { return (keys + ["Shift (either left or right)"]).joined(separator: " + ") }
        return keys.joined(separator: " + ")
    }

    /// What the keys of a chord stand for: "E + T → th   ·   M → i   ·   K + L → ng", colored like the keyboard.
    private func partsText(_ step: TypingStep) -> NSAttributedString {
        guard case let .chord(_, shift) = step.action, !step.parts.isEmpty else { return NSAttributedString() }
        let out = NSMutableAttributedString()
        let keyFont = NSFont.systemFont(ofSize: 13)
        let meaningFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
        func add(_ keys: String, _ meaning: String, _ color: NSColor) {
            if out.length > 0 {
                out.append(NSAttributedString(string: "   ·   ", attributes: [.font: keyFont, .foregroundColor: NSColor.tertiaryLabelColor]))
            }
            out.append(NSAttributedString(string: keys + " → ", attributes: [.font: keyFont, .foregroundColor: NSColor.secondaryLabelColor]))
            out.append(NSAttributedString(string: meaning, attributes: [.font: meaningFont,
                .foregroundColor: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? NSColor.labelColor : color]))
        }
        if shift { add(keyLabel(for: 56), "join", .labelColor) }
        for part in step.parts {
            let keys = part.keys.compactMap { n -> String? in
                guard let i = data.layout.indexByName[n] else { return nil }
                return keyLabel(for: data.layout.keys[i].code)
            }.joined(separator: " + ")
            let role: KeyMeanings.Role?
            switch part.role {
            case .onset: role = .onset
            case .vowel: role = .vowel
            case .coda: role = .coda
            case .spell: role = .spell
            case .capital, .suffix, .symbol, .command: role = .special
            case .digit, .space, .join: role = .number
            case .word, .letter: role = nil
            }
            let meaning = part.role == .word ? part.text + " (word chord)"
                : part.role == .command ? part.text : Self.visible(part.text)
            let roleName: String
            switch part.role {
            case .onset: roleName = "Start: "
            case .vowel: roleName = "Vowel: "
            case .coda: roleName = "End: "
            default: roleName = ""
            }
            add(roleName + keys, meaning, role.map(KeyboardDiagramView.color(for:)) ?? .labelColor)
        }
        return out
    }

    private func targetCodes(_ step: TypingStep) -> Set<KeyCode> {
        var codes = Set<KeyCode>()
        switch step.action {
        case let .chord(names, shift):
            for n in names { if let i = data.layout.indexByName[n] { codes.insert(data.layout.keys[i].code) } }
            if shift { codes.formUnion([56, 60]) }
        case .key(let k):
            switch k {
            case .returnKey: codes.insert(36)
            case .tab: codes.insert(48)
            case .delete: codes.insert(51)
            }
        case .typeNormally:
            codes.formUnion([58, 61])
        }
        return codes
    }

    /// The step's action with its chord keys in the order of its parts (start, vowel, end), so "thing" reads
    /// E + T + M + K + L rather than in keyboard order.
    private func orderedAction(_ step: TypingStep) -> TypingStep.Action {
        guard case let .chord(names, shift) = step.action, !step.parts.isEmpty else { return step.action }
        var ordered: [String] = []
        for p in step.parts { for k in p.keys where !ordered.contains(k) { ordered.append(k) } }
        for k in names where !ordered.contains(k) { ordered.append(k) }
        return .chord(keys: ordered, shift: shift)
    }

    /// The keys of a step as printed on the keyboard, such as "È + T + H" or "⇧ + N + M".
    private func combination(_ a: TypingStep.Action) -> String {
        switch a {
        case let .chord(names, shift):
            let keys = names.map { n -> String in
                guard let i = data.layout.indexByName[n] else { return n }
                return keyLabel(for: data.layout.keys[i].code)
            }
            let join = keyLabel(for: 56)
            return ((shift ? [join] : []) + keys).joined(separator: " + ")
        case .key(let k):
            switch k {
            case .returnKey: return "↩ Return"
            case .tab: return "⇥ Tab"
            case .delete: return "⌫ Delete"
            }
        case .typeNormally(let s):
            return "⌥, type “\(Self.visible(s))”, ⌥"
        }
    }

    private func keyLabel(for code: KeyCode) -> String {
        let meanings = keyMeanings ?? KeyMeanings(data: data, mode: mode)
        return meanings.label(for: code, physical: KeyboardDiagramView.name(for: code), style: practiceSettings.keyLabelStyle)
    }

    private func undoCombination() -> String? {
        let undo = data.shared.entries.first { if case .command(.undo) = $0.value { return true } else { return false } }
        guard let keys = undo?.key else { return nil }
        return combination(.chord(keys: data.layout.names(keys), shift: false))
    }

    static func visible(_ s: String) -> String {
        var out = ""
        for c in s {
            switch c {
            case " ": out += "␣"
            case "\t": out += "⇥"
            case "\n", "\r\n", "\r": out += "↩"
            default: out.append(c)
            }
        }
        return out
    }

    // MARK: Offsets

    private func nsRange(_ r: Range<Int>) -> NSRange {
        let lo = utf16Offsets[max(0, min(r.lowerBound, utf16Offsets.count - 1))]
        let hi = utf16Offsets[max(0, min(r.upperBound, utf16Offsets.count - 1))]
        return NSRange(location: lo, length: max(0, hi - lo))
    }

    /// The character boundary at or before UTF-16 offset `u`.
    private func charIndex(forUTF16 u: Int) -> Int {
        var lo = 0, hi = utf16Offsets.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if utf16Offsets[mid] <= u { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    private func sourceText(_ r: Range<Int>) -> String {
        let lo = max(0, min(r.lowerBound, chars.count)), hi = max(lo, min(r.upperBound, chars.count))
        return String(chars[lo..<hi])
    }

    /// Number of elements of the sorted array `a` that are <= `x`.
    private func upperBound(_ a: [Int], _ x: Int) -> Int {
        var lo = 0, hi = a.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if a[mid] <= x { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
}

// MARK: - Keyboard diagram

/// The MacBook keyboard (`geometry`: US ANSI or Canadian French ISO). Keys to press are outlined in the accent
/// color; keys actually held are filled: green when they belong to the chord, orange when they do not. With
/// `meanings`, each key shows what it stands for (its sound, digit or job) in large type, tinted by role, with the
/// printed legend small in the corner.
final class KeyboardDiagramView: NSView {
    /// The keyboard every diagram draws and names keys by. Set on the main thread by the app controller, from the
    /// Keyboard menu or the keyboard type macOS reports; every diagram redraws when it changes. Both keyboards
    /// have the same size, so the aspect ratios below hold for either.
    static var geometry: KeyboardGeometry = .ansi {
        didSet { NotificationCenter.default.post(name: geometryDidChange, object: nil) }
    }
    static let geometryDidChange = Notification.Name("KeyChordKeyboardGeometryDidChange")

    static let aspect = KeyboardGeometry.height / KeyboardGeometry.width
    /// Height of the function row and the gap below it, in key units.
    static let functionRowHeight = 0.7
    /// Height over width without the function row.
    static let compactAspect = (KeyboardGeometry.height - functionRowHeight) / KeyboardGeometry.width

    var layout: Layout? { didSet { needsDisplay = true } }
    /// Draw Escape and the function keys. The reference overlay leaves them out to save room.
    var showsFunctionRow = true { didSet { needsDisplay = true } }
    /// Exercises emphasize the current chord; the complete colored mapping remains in reference views.
    var emphasizesCurrentChord = false { didSet { needsDisplay = true } }
    /// Fill for held keys when nothing is targeted (default: the accent color), e.g. to mark a chord that types
    /// nothing.
    var heldColor: NSColor? { didSet { needsDisplay = true } }
    var meanings: KeyMeanings? { didSet { needsDisplay = true } }
    var target = Set<KeyCode>() { didSet { if target != oldValue { needsDisplay = true } } }
    var held = Set<KeyCode>() { didSet { if held != oldValue { needsDisplay = true } } }
    /// Matrix Scan: the key to press next (drawn strongest), keys that registered, keys that stayed dark.
    var current: KeyCode? { didSet { if current != oldValue { needsDisplay = true } } }
    var passed = Set<KeyCode>() { didSet { if passed != oldValue { needsDisplay = true } } }
    var failed = Set<KeyCode>() { didSet { if failed != oldValue { needsDisplay = true } } }
    private var keyAccessibilityElements: [KeyCode: NSAccessibilityElement] = [:]

    /// The key's printed label on this keyboard, used to describe chords.
    static func name(for code: KeyCode) -> String { geometry.label(for: code) }
    static func physicalName(for code: KeyCode) -> String {
        let actions: [KeyCode: String] = [36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Escape",
            54: "Right Command", 55: "Left Command", 56: "Left Shift", 57: "Caps Lock", 58: "Left Option",
            59: "Left Control", 60: "Right Shift", 61: "Right Option", 62: "Right Control", 63: "Function"]
        return actions[code] ?? name(for: code)
    }

    /// Key position and size in key units (1 unit = one letter key), origin top left.
    static func rect(for code: KeyCode) -> NSRect? {
        geometry.key(for: code).map { NSRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        NotificationCenter.default.addObserver(self, selector: #selector(geometryChanged), name: Self.geometryDidChange,
                                               object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(geometryChanged), name: Settings.keyLabelsDidChange,
                                               object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(geometryChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func geometryChanged() { needsDisplay = true }

    /// The color of each kind of key when keys are labelled by meaning (also used for chord parts).
    static func color(for role: KeyMeanings.Role) -> NSColor {
        PracticeUI.roleColor(role)
    }

    override var isFlipped: Bool { true }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityChildren() -> [Any]? {
        let top = showsFunctionRow ? 0 : Self.functionRowHeight
        let unit = min(bounds.width / KeyboardGeometry.width, bounds.height / (KeyboardGeometry.height - top))
        let origin = NSPoint(x: (bounds.width - unit * KeyboardGeometry.width) / 2,
                             y: (bounds.height - unit * (KeyboardGeometry.height - top)) / 2 - top * unit)
        return Self.geometry.keys.filter { $0.y >= top }.map { key in
            let element = keyAccessibilityElements[key.code] ?? NSAccessibilityElement()
            keyAccessibilityElements[key.code] = element
            element.setAccessibilityParent(self)
            element.setAccessibilityRole(.staticText)
            let meaning = meanings?.keys[key.code]
            let semantic = meaning.map { $0.label + ", " + PracticeKeyboardTextView.role($0.role) }
                ?? meanings.flatMap { _ in KeyMeanings.modifiers[key.code] } ?? "physical key"
            element.setAccessibilityLabel(Self.physicalName(for: key.code) + ", " + semantic)
            var state = held.contains(key.code) ? "Held down" : "Released"
            if target.contains(key.code) {
                state += [56, 60].contains(key.code) && target.contains(56) && target.contains(60)
                    ? ", target alternative: hold either Shift" : ", target: press next"
            }
            if current == key.code { state += ", current check" }
            if passed.contains(key.code) { state += ", registered" }
            if failed.contains(key.code) { state += ", did not register" }
            element.setAccessibilityValue(state)
            element.setAccessibilityFrameInParentSpace(NSRect(x: origin.x + key.x * unit, y: origin.y + key.y * unit,
                width: key.width * unit, height: key.height * unit))
            return element
        }
    }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }

    override func draw(_ dirtyRect: NSRect) {
        let top = showsFunctionRow ? 0 : Self.functionRowHeight
        let height = KeyboardGeometry.height - top
        let unit = min(bounds.width / KeyboardGeometry.width, bounds.height / height)
        guard unit > 6 else { return }
        // Without the function row, everything moves up by its height.
        let origin = NSPoint(x: ((bounds.width - unit * KeyboardGeometry.width) / 2).rounded(),
                             y: ((bounds.height - unit * height) / 2).rounded() - top * unit)
        let gap = max(2, unit * 0.08)
        let labelFont = NSFont.systemFont(ofSize: max(9, unit * 0.34), weight: .medium)
        let smallFont = NSFont.systemFont(ofSize: max(7, unit * 0.2), weight: .regular)
        let chordKeys = Set(layout?.keys.map(\.code) ?? [])
        let geometry = Self.geometry
        let labelStyle = Settings().keyLabelStyle
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast

        for key in geometry.keys where key.y >= top {
            let r = NSRect(x: origin.x + key.x * unit + gap / 2, y: origin.y + key.y * unit + gap / 2,
                           width: key.width * unit - gap, height: key.height * unit - gap)
            // The ISO Return key is an L; on ANSI it is a plain key.
            let outline = key.code == KeyboardGeometry.returnCode ? geometry.returnOutline : nil
            let path = outline.map { returnPath($0, origin: origin, unit: unit, gap: gap) }
                ?? NSBezierPath(roundedRect: r, xRadius: unit * 0.1, yRadius: unit * 0.1)
            let isTarget = target.contains(key.code), isHeld = held.contains(key.code)
            let inLayout = chordKeys.contains(key.code)
            let meaning = meanings?.keys[key.code]
            // The meaning shown on the key: its sound or job, or Shift's and right Option's job while chording.
            let semantic: String? = meaning.flatMap { $0.label.isEmpty ? nil : $0.label }
                ?? (meanings == nil ? nil : KeyMeanings.modifiers[key.code])
            let shown = labelStyle == .physical || emphasizesCurrentChord && !isTarget && !isHeld ? nil : semantic
            let roleColor: NSColor? = semantic == nil ? nil : contrast ? .labelColor
                : emphasizesCurrentChord ? (isTarget || isHeld ? PracticeUI.accentColor : .secondaryLabelColor)
                : meaning.map { Self.color(for: $0.role) } ?? .labelColor

            var fill: NSColor
            var stroke: NSColor
            var lineWidth: CGFloat = 1
            var text: NSColor = inLayout || key.small ? .labelColor : .secondaryLabelColor
            switch (isHeld, isTarget) {
            case (true, true):
                fill = emphasizesCurrentChord ? PracticeUI.accentColor : .systemGreen; stroke = fill; text = .white
            case (true, false):
                fill = target.isEmpty ? heldColor ?? PracticeUI.accentColor : .systemOrange; stroke = fill; text = .white
            case (false, true):
                fill = PracticeUI.accentColor.withAlphaComponent(0.12); stroke = PracticeUI.accentColor; lineWidth = 2.5
            case (false, false):
                if emphasizesCurrentChord {
                    fill = .controlBackgroundColor; stroke = .separatorColor
                } else if let roleColor, meaning != nil {
                    fill = roleColor.withAlphaComponent(0.08); stroke = roleColor.withAlphaComponent(0.22)
                } else {
                    fill = NSColor.labelColor.withAlphaComponent(inLayout ? 0.09 : 0.035); stroke = .separatorColor
                }
            }
            if !isHeld {
                if failed.contains(key.code) {
                    fill = NSColor.systemRed.withAlphaComponent(0.3); stroke = .systemRed; lineWidth = 1.5
                } else if passed.contains(key.code) {
                    fill = NSColor.systemGreen.withAlphaComponent(0.3); stroke = .systemGreen; lineWidth = 1
                }
                if current == key.code {
                    fill = NSColor.controlAccentColor.withAlphaComponent(0.55); stroke = .controlAccentColor
                    lineWidth = 3.5; text = .white
                }
            }
            if contrast {
                fill = isHeld ? .labelColor : .controlBackgroundColor
                stroke = .labelColor
                text = isHeld ? .controlBackgroundColor : .labelColor
                lineWidth = isTarget || isHeld || current == key.code ? 3.5 : 1.5
            }
            fill.setFill()
            path.fill()
            stroke.setStroke()
            path.lineWidth = lineWidth
            path.stroke()

            let labelRect = outline != nil ? NSRect(x: r.minX, y: r.minY, width: r.width, height: unit - gap) : r
            let cue = isHeld ? "↓" : failed.contains(key.code) ? "×" : passed.contains(key.code) ? "✓" : isTarget ? "○" : ""
            if !cue.isEmpty {
                let marker = NSAttributedString(string: cue, attributes: [.font: smallFont, .foregroundColor: text])
                marker.draw(at: NSPoint(x: labelRect.maxX - marker.size().width - 2, y: labelRect.minY + 1))
            }

            if let shown, labelStyle == .both {
                let main = NSAttributedString(string: key.label, attributes: [.font: key.small ? smallFont : labelFont,
                                                                              .foregroundColor: text])
                let ms = main.size()
                main.draw(at: NSPoint(x: labelRect.midX - ms.width / 2, y: labelRect.midY - ms.height * 0.8))
                if unit >= 22 {
                    let secondary = NSAttributedString(string: shown, attributes: [.font: smallFont,
                        .foregroundColor: isHeld ? (contrast ? NSColor.controlBackgroundColor : NSColor.white.withAlphaComponent(0.9)) : roleColor ?? .secondaryLabelColor])
                    let ss = secondary.size()
                    secondary.draw(at: NSPoint(x: labelRect.midX - ss.width / 2, y: labelRect.maxY - ss.height - unit * 0.05))
                }
                continue
            }
            if let shown {
                // Meaning in large type, the printed legend small in the corner, and what the key does alone
                // (when that is something else) small at the bottom.
                let bigColor = isHeld ? (contrast ? NSColor.controlBackgroundColor : NSColor.white) : roleColor ?? text
                let scale: CGFloat = shown.count <= 2 ? 1 : shown.count <= 4 ? 0.74 : 0.6
                let big = NSAttributedString(string: shown, attributes: [
                    .font: NSFont.systemFont(ofSize: labelFont.pointSize * scale, weight: .semibold),
                    .foregroundColor: bigColor])
                let bs = big.size()
                let alone = unit >= 30 ? meaning?.alone : nil
                let y = alone == nil ? labelRect.midY - bs.height / 2 : labelRect.midY - bs.height * 0.62
                big.draw(at: NSPoint(x: labelRect.midX - bs.width / 2, y: y))
                let dim = isHeld ? (contrast ? NSColor.controlBackgroundColor : NSColor.white.withAlphaComponent(0.85)) : NSColor.secondaryLabelColor
                if labelStyle == .both, !key.label.isEmpty, unit >= 22 {
                    let corner = NSAttributedString(string: key.label, attributes: [.font: smallFont, .foregroundColor: dim])
                    corner.draw(at: NSPoint(x: labelRect.minX + unit * 0.08, y: labelRect.minY + unit * 0.04))
                }
                if let alone {
                    let a = NSAttributedString(string: alone, attributes: [.font: smallFont, .foregroundColor: dim])
                    let s = a.size()
                    a.draw(at: NSPoint(x: labelRect.midX - s.width / 2, y: labelRect.maxY - s.height - unit * 0.05))
                }
                continue
            }

            guard !key.label.isEmpty else { continue }
            let main = NSAttributedString(string: key.label, attributes: [.font: key.small ? smallFont : labelFont,
                                                                          .foregroundColor: text])
            let ms = main.size()
            if let shifted = key.shifted, unit >= 26 {
                let sub = NSAttributedString(string: shifted, attributes: [.font: smallFont, .foregroundColor: text.withAlphaComponent(0.7)])
                let ss = sub.size()
                sub.draw(at: NSPoint(x: labelRect.midX - ss.width / 2, y: labelRect.minY + labelRect.height * 0.08))
                main.draw(at: NSPoint(x: labelRect.midX - ms.width / 2, y: labelRect.maxY - ms.height - labelRect.height * 0.1))
            } else {
                main.draw(at: NSPoint(x: labelRect.midX - ms.width / 2, y: labelRect.midY - ms.height / 2))
            }
        }
    }

    /// The ISO Return key: 1 unit wide on the Q row, 0.75 unit on the A row.
    private func returnPath(_ outline: [(x: Double, y: Double)], origin: NSPoint, unit: CGFloat, gap: CGFloat) -> NSBezierPath {
        let g = gap / 2
        let pts = outline.map { NSPoint(x: origin.x + $0.x * unit, y: origin.y + $0.y * unit) }
        // Inset each corner toward the inside of the L by half the gap.
        let insets: [(CGFloat, CGFloat)] = [(g, g), (-g, g), (-g, -g), (g, -g), (g, -g), (g, -g)]
        let path = NSBezierPath()
        for (i, p) in pts.enumerated() {
            let q = NSPoint(x: p.x + insets[i].0, y: p.y + insets[i].1)
            if i == 0 { path.move(to: q) } else { path.line(to: q) }
        }
        path.close()
        path.lineJoinStyle = .round
        return path
    }
}
