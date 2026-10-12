import AppKit
import KeyChordCore

/// Lessons and listening share the same permission-free local input and verified chord plans.
/// The listening adapter advances only after released chords produced the entire answer.
final class GuidedPracticePane: NSView, NSTextViewDelegate {
    enum Kind { case lessons, voice }
    let kind: Kind
    var onLocalFocus: ((Bool) -> Void)?
    private var data: EngineData
    private var rolloverLimit: Int
    private var usable: (KeySet) -> Bool
    private let defaults: UserDefaults
    private let progress: CourseProgress
    private let speaker: PracticeSpeaking
    private let planningQueue = DispatchQueue(label: "KeyChord.guided-practice", qos: .userInitiated)
    private var request = 0
    private var active = false
    private var preparing = false
    private var random = SystemRandomNumberGenerator()
    private let input: PracticeTypingInputView
    private let browseButton = NSButton()
    private let lessonTitle = PracticeUI.label("", size: 24, weight: .semibold)
    private var lessonBrowser: LessonBrowserView!
    private var browserSurface: NSBox?
    private var lessonPopover: NSPopover?
    private var workspace: NSStackView!
    private var workspaceWidth: NSLayoutConstraint?
    private var browserMinimumHeight: NSLayoutConstraint?
    private var sidebarCollapsed: Bool
    private var completionOverlay: LessonCompletionView?
    private let resultsButton = NSButton(title: "View results", target: nil, action: nil)
    private let lessonProgress = LessonProgressView()
    private let lessonProgressLabel = PracticeUI.label("0% typed", size: 11)
    private let position = PracticeUI.label("", size: 12)
    private let intro = NSTextField(wrappingLabelWithString: "")
    private let passage = NSTextField(wrappingLabelWithString: "")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let hintButton = NSButton(title: "Hint ⇧⌘H", target: nil, action: nil)
    private let replayButton = NSButton(title: "Hear again ⇧⌘R", target: nil, action: nil)
    private let retryButton = NSButton(title: "Retry", target: nil, action: nil)
    private let hint = NSTextField(wrappingLabelWithString: "")
    private let hintCaption = PracticeUI.label("KEYBOARD", size: 10, weight: .semibold)
    private let keyboard = KeyboardDiagramView()
    private var keyboardMaximumHeight: NSLayoutConstraint!
    private var guideCard: NSStackView!
    private var hintedWord: Range<Int>?
    private var introducedSkills: Set<Course.Skill> = []
    private var shownIntroductions: Set<Course.Skill> = []
    private var automaticHint: TypingStep?
    private(set) var isHintRevealed = false
    private(set) var courseIndex: Int
    private(set) var targetText = ""
    private(set) var guide: TypingGuide?
    private(set) var listeningPractice: ListeningPractice?
    private(set) var isFinished = false
    private var planCursor = 0
    private var verifiedOutputStep: Int?
    private var origins: [Bool] = []
    private var chordAttempts = 0
    private var guideKey = ""
    private var displayedStep: TypingStep?
    private var hadError = false
    private var saidError = false
    private var speechUnavailable = false

    init(kind: Kind, data: EngineData, rolloverLimit: Int, usable: @escaping (KeySet) -> Bool,
         defaults: UserDefaults, focus: (() -> Bool)? = nil,
         globalSuspended: @escaping () -> Bool, speaker: PracticeSpeaking = PracticeSpeaker()) {
        self.kind = kind
        self.data = data
        self.rolloverLimit = rolloverLimit
        self.usable = usable
        self.defaults = defaults
        sidebarCollapsed = defaults.bool(forKey: "lessonSidebarCollapsed")
        progress = CourseProgress(defaults: defaults)
        courseIndex = progress.resumeIndex
        self.speaker = speaker
        input = PracticeTypingInputView(data: data, focus: focus, globalSuspended: globalSuspended)
        super.init(frame: .zero)
        input.allowsLocalFocus = false
        buildUI()
        input.delegate = self
        input.onFocus = { [weak self] focused in self?.onLocalFocus?(focused) }
        input.onReadinessChanged = { [weak self] in
            // A focus lease creates a fresh engine. Restore spacing, suffix and capital context
            // even when the visible text and cached hint have not changed.
            self?.guideKey = ""
            self?.refreshGuide()
        }
        input.onCursorChange = { [weak self] in self?.guideKey = ""; self?.refreshGuide() }
        input.onBlockedPaste = { [weak self] in self?.status.stringValue = "Type the exercise; paste is disabled." }
        input.onOrdinaryEdit = { [weak self] in
            guard let self else { return }
            self.guideKey = ""
            self.evaluateInput()
        }
        input.onWillApplyOutput = { [weak self] output in self?.verifyOutput(output) }
        input.onOutput = { [weak self] output in
            guard let self else { return }
            self.keyboard.held = Set(self.input.practice.heldKeys.indices.map { self.data.layout.keys[$0].code })
            if let attempt = output.attempt {
                if attempt.signal != nil {
                    self.status.stringValue = "That chord could not be translated. Try again, or use ⇧⌘H for a hint."
                    if self.kind == .voice { self.say("That chord could not be translated. Try again. Shift Command H gives a hint.") }
                    return
                }
                self.chordAttempts += 1
                if let index = self.verifiedOutputStep {
                    self.planCursor = index + 1
                    self.guideKey = ""
                }
                self.evaluateInput()
            } else if output.routed.events.contains(where: { if case .modeChanged = $0 { return true }; return false }) {
                self.guideKey = ""
                self.refreshGuide()
            }
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    private func buildUI() {
        status.font = .systemFont(ofSize: 13)
        status.textColor = .secondaryLabelColor
        intro.font = .systemFont(ofSize: 14)
        passage.font = .monospacedSystemFont(ofSize: CGFloat(Settings(defaults: defaults).practiceTextSize), weight: .regular)
        passage.setAccessibilityLabel(kind == .voice ? "Spoken practice answer" : "Lesson passage")
        input.placeholder = kind == .voice ? "Type the word you hear…" : "Type the lesson passage…"
        input.font = passage.font
        input.setAccessibilityLabel(kind == .voice ? "Voice practice typing input" : "Lesson typing input")
        input.allowsUndo = false
        input.isContinuousSpellCheckingEnabled = false
        input.isGrammarCheckingEnabled = false
        input.unregisterDraggedTypes()
        input.isVerticallyResizable = true
        input.isHorizontallyResizable = false
        input.autoresizingMask = .width
        input.minSize = NSSize(width: 0, height: 96)
        input.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        input.frame = NSRect(x: 0, y: 0, width: 800, height: 132)
        input.backgroundColor = PracticeUI.surfaceColor
        let inputScroll = NSScrollView()
        inputScroll.documentView = input
        inputScroll.hasVerticalScroller = true
        inputScroll.autohidesScrollers = true
        inputScroll.backgroundColor = PracticeUI.surfaceColor
        inputScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 96).isActive = true
        let inputHeight = inputScroll.heightAnchor.constraint(equalToConstant: 132)
        inputHeight.priority = .init(490); inputHeight.isActive = true
        keyboard.layout = data.layout
        keyboard.emphasizesCurrentChord = true
        keyboard.showsFunctionRow = false
        let keyboardHeight = keyboard.heightAnchor.constraint(equalTo: keyboard.widthAnchor, multiplier: KeyboardDiagramView.compactAspect)
        keyboardHeight.priority = .init(490); keyboardHeight.isActive = true
        keyboardMaximumHeight = keyboard.heightAnchor.constraint(lessThanOrEqualToConstant: 210)
        keyboardMaximumHeight.isActive = true
        hintButton.target = self
        hintButton.action = #selector(hintsChanged)
        hintButton.toolTip = "Reveal the chords for this word · ⇧⌘H"
        replayButton.target = self
        replayButton.action = #selector(replayPrompt)
        replayButton.bezelStyle = .rounded
        replayButton.toolTip = "Repeat the spoken word · ⇧⌘R"
        retryButton.target = self
        retryButton.action = #selector(retry)
        retryButton.bezelStyle = .rounded
        retryButton.toolTip = "Restart this exercise · ⌘R"
        replayButton.title = "Hear again"
        PracticeUI.styleButton(hintButton)
        hintButton.setAccessibilityLabel("Hint for this word")
        guideCard = PracticeHints.keyboardGuide(caption: hintCaption, hint: hint, button: hintButton, keyboard: keyboard)
        PracticeUI.styleButton(replayButton, primary: true)
        var views: [NSView] = []
        if kind == .lessons {
            lessonTitle.textColor = .labelColor
            lessonTitle.lineBreakMode = .byTruncatingTail
            lessonTitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            position.lineBreakMode = .byTruncatingTail
            position.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            browseButton.target = self; browseButton.action = #selector(browseLessons)
            PracticeUI.icon(browseButton, symbol: "sidebar.left", label: "Browse lessons")
            PracticeUI.icon(retryButton, symbol: "arrow.counterclockwise", label: "Restart lesson · ⌘R")
            resultsButton.target = self; resultsButton.action = #selector(showCompletion)
            PracticeUI.styleButton(resultsButton)
            resultsButton.isHidden = true
            let header = PracticeUI.row([browseButton, lessonTitle, PracticeUI.spacer(), resultsButton, retryButton], spacing: 14)
            header.detachesHiddenViews = true
            lessonBrowser = makeLessonBrowser()
            let sidebar = PracticeUI.surface(lessonBrowser, padding: 16)
            sidebar.widthAnchor.constraint(equalToConstant: 284).isActive = true
            browserSurface = sidebar
            let label = PracticeUI.label("TYPE THIS PASSAGE", size: 10, weight: .semibold)
            lessonProgress.setAccessibilityLabel("Lesson passage progress")
            lessonProgress.heightAnchor.constraint(equalToConstant: 6).isActive = true
            views += [header, position, intro,
                PracticeUI.surface(PracticeUI.column([
                    PracticeUI.row([label, PracticeUI.spacer(), lessonProgressLabel]),
                    passage, lessonProgress
                ], spacing: 14), padding: 20)]
        } else {
            PracticeUI.styleButton(retryButton)
            let title = PracticeUI.label("Practice with your eyes closed", size: 22, weight: .semibold)
            title.textColor = .labelColor
            intro.stringValue = "Listen, then type the word with chords. Correct answers move on automatically. Use ⇧⌘R to hear the word again, and ⇧⌘H to hear its keys."
            position.stringValue = "10 spoken words"
            views += [title, intro, position, passage]
            passage.isHidden = true
        }
        views += [PracticeUI.surface(inputScroll, padding: 4), guideCard, status]
        if kind == .voice { views.append(PracticeUI.row([replayButton, retryButton, PracticeUI.spacer()])) }
        workspace = PracticeUI.column(views, spacing: 16)
        if kind == .lessons { workspace.setCustomSpacing(6, after: views[0]) }
        let body: NSView
        if let browserSurface {
            let split = NSStackView(views: [browserSurface, workspace])
            split.orientation = .horizontal; split.alignment = .top; split.spacing = 28
            split.distribution = .fill
            split.detachesHiddenViews = true
            workspace.heightAnchor.constraint(equalTo: split.heightAnchor).isActive = true
            let matchingHeight = browserSurface.heightAnchor.constraint(equalTo: workspace.heightAnchor)
            matchingHeight.priority = .init(490); matchingHeight.isActive = true
            browserMinimumHeight = browserSurface.heightAnchor.constraint(greaterThanOrEqualToConstant: 420)
            browserMinimumHeight?.isActive = true
            workspaceWidth = workspace.widthAnchor.constraint(equalTo: widthAnchor)
            workspace.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            body = split
        } else { body = workspace }
        body.translatesAutoresizingMaskIntoConstraints = false
        addSubview(body)
        workspaceWidth?.isActive = true
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: leadingAnchor), body.trailingAnchor.constraint(equalTo: trailingAnchor),
            body.topAnchor.constraint(equalTo: topAnchor), body.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        hint.stringValue = "Reveal the combination for this word with Hint or ⇧⌘H."
        hint.textColor = .secondaryLabelColor
        hintButton.isEnabled = false
        input.isEditable = false
        replayButton.isEnabled = false
    }

    private var mode: SubMode { kind == .voice ? .english : Course.steps[courseIndex].mode }

    override func layout() {
        let compact = bounds.width < 980
        let showsSidebar = !compact && !sidebarCollapsed
        if browserSurface?.isHidden != !showsSidebar { browserSurface?.isHidden = !showsSidebar }
        let action = compact ? "Browse lessons" : showsSidebar ? "Hide course" : "Show course"
        browseButton.toolTip = action
        browseButton.setAccessibilityLabel(action)
        browseButton.setAccessibilityValue(showsSidebar ? "Expanded" : "Collapsed")
        browseButton.contentTintColor = showsSidebar ? PracticeUI.accentColor : .secondaryLabelColor
        workspaceWidth?.constant = showsSidebar ? -312 : 0
        browserMinimumHeight?.constant = compact ? 420 : max(420, (window?.contentView?.bounds.height ?? 810) - 104)
        // Let the input grow on a large page, while keeping the keyboard and its Hint action in view.
        if let content = window?.contentView {
            keyboardMaximumHeight.constant = max(140, content.bounds.height * 0.26)
        }
        super.layout()
    }

    private func makeLessonBrowser() -> LessonBrowserView {
        let browser = LessonBrowserView(selectedIndex: courseIndex, completed: progress.completed)
        browser.onSelect = { [weak self] index in
            self?.lessonPopover?.close()
            self?.openLesson(index)
        }
        return browser
    }
    @objc private func browseLessons() {
        if bounds.width >= 980 {
            sidebarCollapsed.toggle()
            defaults.set(sidebarCollapsed, forKey: "lessonSidebarCollapsed")
            lessonPopover?.close()
            needsLayout = true
            window?.contentView?.layoutSubtreeIfNeeded()
            if !sidebarCollapsed { lessonBrowser.revealCurrentLesson() }
            focusInput()
            return
        }
        showLessonBrowser()
    }

    private func showLessonBrowser() {
        if lessonPopover?.isShown == true { lessonPopover?.close(); return }
        let browser = makeLessonBrowser()
        let controller = NSViewController()
        let host = NSView()
        browser.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(browser)
        NSLayoutConstraint.activate([
            browser.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 16),
            browser.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -16),
            browser.topAnchor.constraint(equalTo: host.topAnchor, constant: 16),
            browser.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -16)
        ])
        controller.view = host
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        popover.contentSize = NSSize(width: 352, height: 560)
        lessonPopover = popover
        popover.show(relativeTo: browseButton.bounds, of: browseButton, preferredEdge: .maxY)
        browser.revealCurrentLesson()
    }

    func openLesson(_ index: Int) {
        guard Course.steps.indices.contains(index), kind == .lessons else { return }
        courseIndex = index
        progress.lastStep = Course.steps[index].id
        lessonBrowser.reload(selectedIndex: index, completed: progress.completed)
        let step = Course.steps[index]
        lessonTitle.stringValue = step.title
        updateLessonPosition()
        intro.stringValue = step.id == "first-chord"
            ? "Chord typing is ready here. Hold the start, vowel and end keys together, then release every key before the next chord. KeyChord adds the space before each word. Right Option switches to ordinary typing."
            : step.intro
        introducedSkills = PracticeHints.newSkills(at: index, data: data)
        shownIntroductions = []
        beginPlanning()
        let request = request, data = data, limit = rolloverLimit, usable = usable
        planningQueue.async { [weak self] in
            let guide = TypingPlanner(data: data, mode: step.mode, rolloverLimit: limit, usable: usable).plan(step.text)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.request == request else { return }
                self.install(text: step.text, guide: guide)
            }
        }
    }

    private func updateLessonPosition() {
        let placement = Course.position(of: courseIndex)
        let steps = Course.steps.filter { $0.mode == mode }
        let completed = progress.completed
        let done = steps.filter { completed.contains($0.id) }.count
        position.stringValue = "\(Course.units[placement.unit].title) · Lesson \(placement.step + 1) of \(Course.units[placement.unit].steps.count) · \(done) of \(steps.count) practiced"
    }

    private func beginPlanning() {
        request += 1
        preparing = true
        dismissCompletion()
        isFinished = false
        resultsButton.isHidden = true
        lessonProgress.fraction = 0
        lessonProgressLabel.stringValue = "0% typed"
        speaker.stop()
        input.isEditable = false
        input.relinquishFocus()
        clearHint(message: "Preparing practice…")
        hintButton.isEnabled = false
        status.stringValue = "Preparing practice…"
        replayButton.isEnabled = false
    }

    private func startListening() {
        beginPlanning()
        let request = request, data = data, limit = rolloverLimit, usable = usable
        planningQueue.async { [weak self] in
            let session = ListeningPractice(data: data, rolloverLimit: limit, usable: usable, sessionLength: 10)
            var random = SystemRandomNumberGenerator()
            let prompt = session.next(using: &random)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.request == request else { return }
                self.listeningPractice = session
                guard let prompt else {
                    self.preparing = false
                    self.status.stringValue = "No spoken practice words are available for this mapping and keyboard."
                    self.say(self.status.stringValue)
                    return
                }
                self.install(text: prompt.text, guide: prompt.guide)
                self.say("Word 1 of 10: " + prompt.text)
            }
        }
    }

    private func install(text: String, guide: TypingGuide, preservingInput: Bool = false) {
        preparing = false
        targetText = text
        self.guide = guide
        keyboard.meanings = KeyMeanings(data: data, mode: mode)
        keyboard.layout = data.layout
        if !preservingInput {
            isFinished = false
            planCursor = 0
            origins = []
            chordAttempts = 0
            hadError = false
            saidError = false
            input.clearForTask()
            hintedWord = nil; automaticHint = nil
        }
        input.practice.setMode(mode)
        input.isEditable = !isFinished
        guideKey = ""
        replayButton.isEnabled = kind == .voice && !isFinished
        status.stringValue = "Hold the chord keys together, then release every key."
        if kind == .voice {
            position.stringValue = "\(listeningPractice?.completedWords ?? 0) of 10 words complete · \(listeningPractice?.assistedWords ?? 0) assisted"
        }
        refreshGuide()
        if active { focusInput() }
    }

    func activate() {
        active = true
        input.allowsLocalFocus = true
        if guide == nil, !preparing {
            if kind == .lessons { openLesson(courseIndex) } else { startListening() }
        } else if !preparing {
            if isFinished, kind == .lessons { showCompletion(); return }
            focusInput()
            guideKey = ""
            refreshGuide()
            if kind == .voice { replayPrompt() }
        }
    }
    func deactivate() {
        active = false
        dismissCompletion()
        lessonPopover?.close()
        input.allowsLocalFocus = false
        speaker.stop()
        input.relinquishFocus()
    }
    func focusInput() {
        guard active, !preparing, !isFinished else { return }
        window?.makeFirstResponder(input)
        input.refreshFocus()
        refreshGuide()
    }

    @objc func retry() {
        guard !preparing else { return }
        if kind == .lessons { openLesson(courseIndex) }
        else if isFinished || listeningPractice?.prompt == nil { startListening() }
        else if let prompt = listeningPractice?.prompt {
            install(text: prompt.text, guide: prompt.guide)
            say(prompt.text)
        }
    }
    @objc func nextLesson() {
        if kind == .voice { if isFinished { startListening() }; return }
        guard !preparing, isFinished else { return }
        if let nextCourseIndex { openLesson(nextCourseIndex) }
        else {
            dismissCompletion()
            sidebarCollapsed = false
            defaults.set(false, forKey: "lessonSidebarCollapsed")
            needsLayout = true
            window?.contentView?.layoutSubtreeIfNeeded()
            if bounds.width < 980 { showLessonBrowser() }
            else { lessonBrowser.revealCurrentLesson() }
        }
    }

    private var nextCourseIndex: Int? {
        let next = courseIndex + 1
        return Course.steps.indices.contains(next) && Course.steps[next].mode == mode ? next : nil
    }

    @objc private func showCompletion() {
        guard kind == .lessons, active, isFinished, completionOverlay == nil,
              let host = window?.contentView else { return }
        let indices = Course.steps.indices.filter { Course.steps[$0].mode == mode }
        let completed = progress.completed
        let done = indices.filter { completed.contains(Course.steps[$0].id) }.count
        let next = nextCourseIndex.map { Course.steps[$0] }
        let overlay = LessonCompletionView(lesson: Course.steps[courseIndex].title,
            language: mode == .english ? "English" : "C++", completed: done, total: indices.count,
            nextTitle: next?.title,
            nextUnit: nextCourseIndex.map { Course.units[Course.position(of: $0).unit].title })
        overlay.onContinue = { [weak self] in self?.nextLesson() }
        overlay.onRetry = { [weak self] in self?.retry() }
        overlay.onDismiss = { [weak self] in self?.dismissCompletion() }
        overlay.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: host.leadingAnchor), overlay.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: host.topAnchor), overlay.bottomAnchor.constraint(equalTo: host.bottomAnchor)
        ])
        completionOverlay = overlay
        host.layoutSubtreeIfNeeded()
        window?.makeFirstResponder(overlay.continueButton)
        NSAccessibility.post(element: overlay, notification: .announcementRequested, userInfo: [
            .announcement: "Lesson complete. " + Course.steps[courseIndex].title,
            .priority: NSAccessibilityPriorityLevel.high.rawValue
        ])
    }

    private func dismissCompletion() {
        guard let overlay = completionOverlay else { return }
        if let responder = window?.firstResponder as? NSView, responder.isDescendant(of: overlay) {
            window?.makeFirstResponder(nil)
        }
        overlay.removeFromSuperview()
        completionOverlay = nil
    }
    @objc func replayPrompt() {
        guard kind == .voice, !preparing else { return }
        if isFinished { say(status.stringValue) }
        else if !targetText.isEmpty { say(targetText); focusInput() }
    }
    func requestHint() {
        guard !preparing, !isFinished else { return }
        refreshGuide()
        guard let step = displayedStep else { focusInput(); return }
        hintedWord = PracticeHints.wordRange(for: step, in: targetText)
        if kind == .voice { listeningPractice?.revealHint() }
        guideKey = ""
        refreshGuide()
        if kind == .voice, let guide, let hintedWord {
            say(guide.steps.filter { PracticeHints.wordRange(for: $0, in: targetText).overlaps(hintedWord) }
                .map(spokenHint).joined(separator: ". "))
        }
        focusInput()
    }
    @objc private func hintsChanged() { requestHint() }

    private func say(_ text: String) {
        guard active, kind == .voice else { return }
        speechUnavailable = !speaker.isAvailable || !speaker.speak(text)
        if speechUnavailable {
            passage.isHidden = false
            passage.stringValue = targetText
            listeningPractice?.revealHint()
            status.stringValue = "No English voice is available. Enable one in macOS Spoken Content, then retry Voice practice."
        }
    }

    func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
        guard textView === input, !preparing, !isFinished, let replacement = replacementString,
              range.location >= 0, range.location + range.length <= origins.count else { return false }
        if !input.isApplyingChordOutput, replacement.count > 1 { input.onBlockedPaste?(); return false }
        let structural = input.practice.chordEnabled && !replacement.isEmpty && replacement.allSatisfy { $0 == "\n" || $0 == "\t" }
        origins.replaceSubrange(range.location..<(range.location + range.length),
            with: repeatElement(input.isApplyingChordOutput || structural, count: replacement.utf16.count))
        return true
    }

    private func verifyOutput(_ output: LocalChordOutput) {
        verifiedOutputStep = nil
        guard let attempt = output.attempt, attempt.signal == nil, let guide,
              input.selectedRange() == NSRange(location: input.string.utf16.count, length: 0) else { return }
        var projected = Array(input.string)
        for action in output.routed.actions {
            switch action {
            case .insert(let text): projected.append(contentsOf: text)
            case .deleteBackward(let count):
                guard count <= projected.count else { return }
                projected.removeLast(count)
            default: return
            }
        }
        for index in guide.steps.indices where index >= planCursor {
            let step = guide.steps[index]
            guard String(projected) == expected(after: step), case .chord(let names, _) = step.action,
                  data.layout.keySet(names: names) == attempt.keys else { continue }
            verifiedOutputStep = index
            return
        }
    }
    private func expected(after step: TypingStep) -> String { String(targetText.prefix(step.prefixEnd)) + step.tail }

    private func evaluateInput() {
        guard !preparing, !isFinished, guide != nil else { return }
        if input.string == targetText {
            if kind == .lessons { renderPassage() }
            guard chordAttempts > 0, origins.count == input.string.utf16.count, origins.allSatisfy({ $0 }) else {
                status.stringValue = "Text matched. Retry with chords to complete this exercise."
                if kind == .voice, !saidError { say(status.stringValue); saidError = true }
                return
            }
            if kind == .lessons {
                isFinished = true
                progress.markDone(Course.steps[courseIndex].id)
                lessonBrowser.reload(selectedIndex: courseIndex, completed: progress.completed)
                status.stringValue = "Lesson complete."
                updateLessonPosition()
                resultsButton.isHidden = false
                input.isEditable = false
                input.relinquishFocus()
                clearHint(message: "Lesson complete. Continue or retry to keep practicing.")
                hintButton.isEnabled = false
                keyboard.held = []
                showCompletion()
            } else if let session = listeningPractice, session.check(input.string) {
                if session.isSessionComplete {
                    isFinished = true
                    status.stringValue = "Voice practice complete. \(session.completedWords) words, \(session.assistedWords) assisted. Command R starts again."
                    position.stringValue = "10 of 10 words complete · \(session.assistedWords) assisted"
                    input.isEditable = false
                    input.relinquishFocus()
                    clearHint(message: "Voice practice complete. Retry to start again.")
                    hintButton.isEnabled = false
                    replayButton.isEnabled = true
                    say("Correct. " + status.stringValue)
                } else if let prompt = session.next(using: &random) {
                    install(text: prompt.text, guide: prompt.guide)
                    say("Correct. Word \(session.completedWords + 1) of 10: \(prompt.text)")
                }
            }
            return
        }
        guideKey = ""
        refreshGuide()
        if hadError, kind == .voice, !saidError {
            saidError = true
            say("Not quite. Press Backspace to correct it. Shift Command R repeats the word. Shift Command H gives a hint.")
        } else if !hadError { saidError = false }
    }

    private func refreshGuide() {
        guard let guide, !preparing, !isFinished else { return }
        hintButton.isEnabled = input.practice.chordEnabled
        let key = input.string + "|\(input.selectedRange().location)|\(planCursor)|\(input.practice.chordEnabled)"
        guard guideKey != key else { return }
        guideKey = key
        let typed = input.string
        let atEnd = input.selectedRange() == NSRange(location: typed.utf16.count, length: 0)
        let previous = planCursor > 0 && guide.steps.indices.contains(planCursor - 1) ? guide.steps[planCursor - 1] : nil
        let onPlannedState = previous.map { expected(after: $0) == typed } ?? typed.isEmpty
        hadError = !targetText.hasPrefix(typed) && !onPlannedState
        displayedStep = nil
        if !atEnd {
            showNeutralKeyboard(message: "Move to the end of your input for the next chord.")
            updatePassageVisibility()
            return
        }
        if hadError {
            showNeutralKeyboard(message: "Press Backspace to correct the mistake.")
            updatePassageVisibility()
            status.stringValue = "Not quite. Correct the mistake, or use ⇧⌘H for a hint."
            return
        }
        status.stringValue = kind == .voice && speechUnavailable
            ? "No English voice is available. Enable one in macOS Spoken Content, then retry Voice practice."
            : kind == .voice ? "Listen, then type the word. ⇧⌘R repeats it; ⇧⌘H reads the keys."
            : "Hold the chord keys together, then release every key. Right Option switches to ordinary typing."
        let next: TypingStep?
        if onPlannedState {
            if let context = previous?.contextAfter { input.practice.restoreContext(context) }
            else if typed.isEmpty { input.practice.restoreContext(.initial) }
            next = planCursor < guide.steps.count ? guide.steps[planCursor] : nil
        } else if let index = guide.steps.lastIndex(where: { $0.tail.isEmpty && expected(after: $0) == typed }) {
            planCursor = index + 1
            if let context = guide.steps[index].contextAfter { input.practice.restoreContext(context) }
            next = planCursor < guide.steps.count ? guide.steps[planCursor] : nil
        } else {
            let continuation = TypingPlanner(data: data, mode: mode, rolloverLimit: rolloverLimit, usable: usable)
                .planContinuation(targetText, from: typed.count)
            input.practice.restoreContext(continuation.startContext)
            next = continuation.guide.steps.first
        }
        guard let next else {
            clearHint(message: "This passage is typed. Retry with chords to complete it.")
            updatePassageVisibility()
            return
        }
        displayedStep = next
        let word = PracticeHints.wordRange(for: next, in: targetText)
        if let requested = hintedWord, !requested.overlaps(word) { hintedWord = nil }
        if automaticHint != next { automaticHint = nil }
        if kind == .lessons, input.practice.chordEnabled {
            let newlyUsed = Course.skills(of: next, data: data, mode: mode)
                .intersection(introducedSkills).subtracting(shownIntroductions)
            if !newlyUsed.isEmpty {
                shownIntroductions.formUnion(newlyUsed)
                automaticHint = next
            }
        }
        isHintRevealed = input.practice.chordEnabled && (hintedWord != nil || automaticHint != nil)
        if isHintRevealed {
            hintCaption.stringValue = hintedWord == nil ? "NEW COMBINATION" : "THIS WORD"
            hint.textColor = .labelColor
            hint.stringValue = visibleHint(next)
            keyboard.target = []
            switch next.action {
            case .chord(let names, let shift):
                keyboard.target = Set(names.compactMap { data.layout.indexByName[$0] }.map { data.layout.keys[$0].code } + (shift ? [56] : []))
            case .key(let key):
                keyboard.target = [key == .returnKey ? 36 : key == .tab ? 48 : 51]
            case .typeNormally: break
            }
        } else {
            showNeutralKeyboard(message: input.practice.chordEnabled
                ? "Reveal the combination for this word with Hint or ⇧⌘H."
                : "Tap right Option to use chords.")
        }
        updatePassageVisibility()
    }

    private func showNeutralKeyboard(message: String) {
        isHintRevealed = false
        keyboard.target = []
        hintCaption.stringValue = "KEYBOARD"
        hint.textColor = .secondaryLabelColor
        hint.stringValue = message
    }
    private func clearHint(message: String) {
        hintedWord = nil; automaticHint = nil
        showNeutralKeyboard(message: message)
    }
    private func updatePassageVisibility() {
        passage.isHidden = kind == .voice && !isHintRevealed && !speechUnavailable
        if !passage.isHidden { renderPassage() }
    }

    private func spokenHint(_ step: TypingStep) -> String {
        switch step.action {
        case .chord(let names, let shift):
            let keys = names.compactMap { data.layout.indexByName[$0] }.map { spokenKey(data.layout.keys[$0].code) } + (shift ? ["Shift"] : [])
            return keys.joined(separator: ", ")
        case .key(let key): return key.rawValue
        case .typeNormally(let text): return text
        }
    }
    private func visibleHint(_ step: TypingStep) -> String {
        switch step.action {
        case .chord:
            let output = step.output.trimmingCharacters(in: .whitespacesAndNewlines)
            return (output.isEmpty ? step.note : output) + ": " + spokenHint(step).replacingOccurrences(of: ", ", with: " + ")
        case .key(let key): return key.rawValue
        case .typeNormally(let text): return "Tap right Option and type \(text)."
        }
    }
    private func spokenKey(_ code: KeyCode) -> String {
        let label = KeyboardDiagramView.name(for: code)
        return [";": "Semicolon", "'": "Quote", "[": "Left bracket", "]": "Right bracket",
                "\\": "Backslash", ",": "Comma", ".": "Period", "/": "Slash", "=": "Equal", "-": "Minus",
                "⌫": "Backspace", "␣": "Space", "⇧": "Shift", "↵": "Return", "⇥": "Tab"][label] ?? label
    }
    private func renderPassage() {
        if kind == .lessons {
            let matched = zip(input.string, targetText).prefix { $0 == $1 }.count
            lessonProgress.fraction = targetText.isEmpty ? 0 : Double(matched) / Double(targetText.count)
            lessonProgressLabel.stringValue = "\(Int(lessonProgress.fraction * 100))% typed"
        }
        let output = NSMutableAttributedString(string: targetText, attributes: [.font: passage.font!, .foregroundColor: NSColor.secondaryLabelColor])
        let typed = Array(input.string), expected = Array(targetText)
        var offset = 0
        let planned = guide?.steps.contains { self.expected(after: $0) == input.string } ?? false
        for (index, character) in expected.enumerated() {
            if index < typed.count {
                output.addAttribute(.foregroundColor, value: planned || typed[index] == character ? NSColor.labelColor : NSColor.systemRed,
                    range: NSRange(location: offset, length: String(character).utf16.count))
            }
            offset += String(character).utf16.count
        }
        passage.attributedStringValue = output
    }

    func update(data: EngineData, rolloverLimit: Int, usable: @escaping (KeySet) -> Bool) {
        self.data = data; self.rolloverLimit = rolloverLimit; self.usable = usable
        input.practice.replaceData(data)
        guideKey = ""
        guard guide != nil || preparing else { return }
        if kind == .voice { startListening() }
        else {
            let text = targetText.isEmpty ? Course.steps[courseIndex].text : targetText
            let guide = TypingPlanner(data: data, mode: mode, rolloverLimit: rolloverLimit, usable: usable).plan(text)
            request += 1
            install(text: text, guide: guide, preservingInput: true)
        }
    }
}
