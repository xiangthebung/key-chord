// Spoken prompts use everyday words with unambiguous spelling. Each answer is checked against
// the actual chord map and keyboard limits before it can enter a session.
public final class ListeningPractice {
    public private(set) var prompt: GeneratedPractice?
    public private(set) var hintRevealed = false
    public private(set) var completedWords = 0
    public private(set) var assistedWords = 0
    /// Whether the current prompt has been answered. Finite-session completion is separate.
    public private(set) var isComplete = false
    public let sessionLength: Int?
    public var isSessionComplete: Bool { sessionLength.map { completedWords >= $0 } ?? false }
    public var canAdvance: Bool { prompt != nil && isComplete && !isSessionComplete }
    public var isAvailable: Bool { !words.isEmpty }
    private let words: [GeneratedPractice]
    private var remaining: [Int] = []

    public init(data: EngineData, rolloverLimit: Int = 6, usable: @escaping (KeySet) -> Bool = { _ in true },
                learnedSkills: Set<Course.Skill>? = nil, sessionLength: Int? = nil) {
        self.sessionLength = sessionLength.map { max(0, $0) }
        let planner = TypingPlanner(data: data, mode: .english, rolloverLimit: rolloverLimit, usable: usable)
        words = Self.vocabulary.split(whereSeparator: \.isWhitespace).compactMap { token in
            let word = String(token)
            let guide = planner.plan(word)
            guard !guide.steps.isEmpty, guide.steps.allSatisfy(Course.isAllowed) else { return nil }
            if let learnedSkills {
                guard guide.steps.allSatisfy({
                    Course.skills(of: $0, data: data, mode: .english).isSubset(of: learnedSkills)
                }) else { return nil }
            }
            return GeneratedPractice(text: word, guide: guide)
        }
    }

    /// Every usable word appears before the bag starts again; bag boundaries avoid immediate repeats.
    /// A finite session waits for a correct answer and an explicit next call, then ends at its goal.
    /// With no length, the original endless, freely advancing behavior remains available.
    @discardableResult
    public func next<R: RandomNumberGenerator>(using random: inout R) -> GeneratedPractice? {
        guard !words.isEmpty, !isSessionComplete else { return nil }
        if sessionLength != nil, prompt != nil, !isComplete { return prompt }
        if remaining.isEmpty { remaining = Array(words.indices).shuffled(using: &random) }
        if remaining.count > 1, words[remaining.last!].text == prompt?.text {
            remaining.swapAt(0, remaining.count - 1)
        }
        prompt = words[remaining.removeLast()]
        hintRevealed = false
        isComplete = false
        return prompt
    }

    @discardableResult
    public func revealHint() -> Bool {
        guard prompt != nil, !isComplete else { return false }
        hintRevealed = true
        return true
    }

    /// Partial words and errors stay on the same prompt. Repeated callbacks for an answer count once.
    @discardableResult
    public func check(_ typed: String) -> Bool {
        guard let prompt, !isComplete, typed == prompt.text else { return false }
        isComplete = true
        completedWords += 1
        if hintRevealed { assistedWords += 1 }
        return true
    }

    private static let vocabulary = """
        hat sat at tan an sit hit tin hut hot sun set ten red rat fat dad did let get wet
        cat dog rabbit tiger lion monkey panda elephant dolphin penguin turtle spider
        apple banana lemon mango orange carrot potato tomato onion pumpkin pepper
        table chair window kitchen garden bedroom house school library hospital
        mother father sister brother family baby friend teacher student person
        happy angry hungry sleepy tired excited funny quiet brave clever gentle
        yellow purple green pink black silver golden bright dark colorful
        evening summer winter spring autumn sunny cloudy snowy windy
        jump walk run swim dance sing smile laugh think sleep dream play learn
        making running swimming jumping helping playing learning working singing
        slowly quickly carefully faster bigger smaller longest nicest kindness
        book pencil paper letter story picture music game puzzle number lesson
        mountain river forest island desert ocean lake planet rocket
        bicycle football basketball tennis camera computer keyboard telephone
        butterfly strawberry chocolate sandwich breakfast dinner water coffee
        animal people children together another anything everything something
        remember practice important favorite beautiful different wonderful
        hello goodbye please thank welcome amazing easy difficult simple
        button pocket jacket sweater blanket pillow glasses candle basket
        balloon castle dragon robot dinosaur astronaut adventure treasure
        """
}
