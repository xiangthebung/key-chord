// The KeyChord course: small steps, each teaching a few keys or one idea, with a short text that uses only what
// the course has taught so far. The tests check every step on the default layout, on any keyboard and on the
// MacBook Pro 2021: it is typed with chords only, needs nothing the course hasn't taught yet, and practices what
// it introduces. The Typing Guide runs the course; the keys it shows for each new item come from the active
// layout and dictionaries. Standard library only.

public enum Course {
    /// Something a step teaches.
    public enum Skill: Hashable, Sendable {
        /// A sound at the start of a syllable, its vowel, or its end.
        case sound(Bank, String)
        /// Sounds of one bank pressed together, where the result is just their letters (s + t = st): every such
        /// cluster of the layout, once its single sounds are taught.
        case pairs(Bank)
        /// A word with a chord of its own (a brief).
        case word(String)
        /// An ending joined to the word before, such as "ing".
        case ending(String)
        /// Punctuation or an operator: every chord for this text (opening and closing quotes, ...), except the
        /// forms of . ? and ! without the automatic capital.
        case symbol(String)
        /// . ? or ! without the automatic capital after it, for abbreviations.
        case abbreviation(String)
        case command(Command)
        /// The space bar held with a chord, which joins it to the word before.
        case join
        /// Shift held with a chord, for chords that can't take the space bar.
        case shiftJoin
        /// The space bar alone.
        case space
        /// The spell key with a letter's key.
        case spell
        /// The spell key, the capital key and a letter's key.
        case capitalLetter
        case digits
        /// Return.
        case newLine

        /// Whether the skill works the same way in both sub-modes. Dictionary entries belong to their mode.
        var carriesOver: Bool {
            switch self {
            case .word, .ending, .symbol, .abbreviation: return false
            default: return true
            }
        }
    }

    public struct Step: Equatable, Sendable {
        /// Stable name, for saved progress.
        public let id: String
        public let title: String
        /// What the step teaches, in a few sentences.
        public let intro: String
        /// What is new in this step, shown with its keys.
        public let new: [Skill]
        /// The text to type.
        public let text: String
        public let mode: SubMode

        public init(id: String, title: String, intro: String, new: [Skill], text: String, mode: SubMode = .english) {
            self.id = id
            self.title = title
            self.intro = intro
            self.new = new
            self.text = text
            self.mode = mode
        }
    }

    public struct Unit: Equatable, Sendable {
        public let title: String
        public let steps: [Step]
    }

    /// Every step, in order.
    public static let steps: [Step] = units.flatMap(\.steps)

    public static func index(of id: String) -> Int? { steps.firstIndex { $0.id == id } }

    /// Version 2 divides dense introductions while keeping their original identifiers.
    public static let curriculumVersion = 2

    /// Completion of an old lesson covers all of the smaller lessons that replaced its content.
    /// Call only when loading persisted progress, then save the current curriculum version.
    public static func migratedCompletedIDs(_ ids: Set<String>, fromVersion: Int) -> Set<String> {
        guard fromVersion < curriculumVersion else { return ids }
        var migrated = ids
        for (original, additions) in legacyLessonExpansions where ids.contains(original) {
            migrated.formUnion(additions)
        }
        return migrated
    }

    public static let legacyLessonExpansions: [String: Set<String>] = [
        "first-chord": ["first-ends"],
        "vowels": ["right-thumb-vowels"],
        "home-row": ["home-row-more"],
        "two-key-starts": ["two-key-starts-ck"],
        "two-key-ends": ["two-key-ends-wx"],
        "end-sounds": ["end-sounds-sh-ch-th", "end-sounds-ss-ft-ct", "end-sounds-kl"],
        "blends": ["blends-pr-sk-sm", "blends-sn-sp-kn-qu"],
        "vowel-pairs": ["vowel-pairs-ou-ai"],
        "word-chords": ["word-chords-into-other-only", "word-chords-over-also-after-first"],
        "more-word-chords": ["more-word-chords-between-never-every", "more-word-chords-little-different-important-something"],
        "cpp-mode": ["cpp-more-keywords"],
        "cpp-symbols": ["cpp-symbols-round", "cpp-symbols-braces"],
    ]

    /// The unit step `i` belongs to, and its place in that unit (both 0-based).
    public static func position(of i: Int) -> (unit: Int, step: Int) {
        var first = 0
        for (u, unit) in units.enumerated() {
            if i < first + unit.steps.count { return (u, i - first) }
            first += unit.steps.count
        }
        return (max(0, units.count - 1), 0)
    }

    /// Introduced to be explained rather than practiced: no text needs them.
    public static let explainedOnly: Set<Skill> = [.command(.undo), .command(.modeSwitch)]

    // MARK: Skills

    /// Everything steps 0 through `i` have taught, for the mode of step `i`, including the pairs of letters
    /// that `pairs` covers in `data`'s layout.
    public static func taught(through i: Int, data: EngineData) -> Set<Skill> {
        guard i >= 0, i < steps.count else { return [] }
        return learnedSkills(completedIDs: Set(steps[...i].map(\.id)), data: data, mode: steps[i].mode)
    }

    /// Skills from completed lessons, including pair rules only for components actually learned.
    /// Unlike a contiguous course index, this also supports learners who explored lessons out of order.
    public static func learnedSkills(completedIDs: Set<String>, data: EngineData,
                                     mode: SubMode = .english) -> Set<Skill> {
        var out = Set<Skill>()
        for s in steps where completedIDs.contains(s.id) {
            for k in s.new where s.mode == mode || k.carriesOver { out.insert(k) }
        }
        for bank in Bank.allCases where out.contains(.pairs(bank)) {
            for c in pairClusters(bank, data: data) where c.singles.allSatisfy({ out.contains(.sound(bank, $0)) }) {
                out.insert(.sound(bank, c.text))
            }
        }
        return out
    }

    /// Clusters made of their keys' own sounds, with those sounds.
    static func pairClusters(_ bank: Bank, data: EngineData) -> [(text: String, keys: KeySet, singles: [String])] {
        let table = data.layout.clusters[bank] ?? [:]
        return table.compactMap { keys, text in
            guard KeyMeanings.isMadeOfItsKeys(keys, text, in: table) else { return nil }
            return (text, keys, keys.indices.compactMap { table[KeySet([$0])] })
        }.sorted { ($0.text, $0.keys.bits) < ($1.text, $1.keys.bits) }
    }

    /// Whether the course can ask for a planned step: never Normal_Mode typing, or a throwaway letter and Delete.
    public static func isAllowed(_ s: TypingStep) -> Bool {
        switch s.action {
        case .typeNormally, .key(.delete): return false
        default: return s.kind != .cancelCapital
        }
    }

    /// What a planned step asks the typist to know.
    public static func skills(of step: TypingStep, data: EngineData, mode: SubMode) -> Set<Skill> {
        let layout = data.layout
        func entry(_ names: [String]) -> Entry? {
            guard let k = layout.keySet(names: names) else { return nil }
            return data.dictionary(for: mode)[k] ?? data.shared[k]
        }
        var out = Set<Skill>()
        switch step.action {
        case .key(.returnKey), .key(.tab): out.insert(.newLine)
        case .key(.delete), .typeNormally: break
        case .chord(_, let shift):
            if shift { out.insert(.shiftJoin) }
            for p in step.parts {
                switch p.role {
                case .onset, .vowel, .coda:
                    let bank: Bank = p.role == .onset ? .onset : p.role == .vowel ? .vowel : .coda
                    let text = layout.keySet(names: p.keys).flatMap { layout.clusters[bank]?[$0] } ?? p.text
                    out.insert(.sound(bank, text))
                case .word, .suffix, .symbol:
                    if case .text(let t)? = entry(p.keys) {
                        switch t.kind {
                        case .suffix: out.insert(.ending(t.text))
                        case .symbol: out.insert(isAbbreviation(t, mode: mode) ? .abbreviation(t.text) : .symbol(t.text))
                        case .word: out.insert(.word(t.text))
                        }
                    } else {
                        out.insert(p.role == .suffix ? .ending(p.text) : p.role == .symbol ? .symbol(p.text) : .word(p.text))
                    }
                case .command:
                    if case .command(let c)? = entry(p.keys) { out.insert(.command(c)) }
                case .spell, .letter: out.insert(.spell)
                case .capital: out.insert(.capitalLetter)
                case .digit: out.insert(.digits)
                case .space: out.insert(.space)
                case .join: out.insert(.join)
                }
            }
        }
        return out
    }

    static func isAbbreviation(_ t: TextEntry, mode: SubMode) -> Bool {
        mode == .english && !t.capitalizeNext && [".", "?", "!"].contains(t.text)
    }

    // MARK: Keys for a skill

    /// A chord to show for a new skill.
    public struct Chord: Equatable, Sendable {
        /// What it types or does: "th", "-ing", "their", "capital on the next word".
        public let label: String
        /// Layout keys pressed together; empty for skills that are not one chord (digits, Return).
        public let keys: KeySet
        /// Hold Shift with it.
        public let shift: Bool
        /// For coloring, as on the keyboard picture; nil for words.
        public let role: KeyMeanings.Role?
        /// A few words more: "opening", "+ a letter", "the number row".
        public let note: String?

        public init(label: String, keys: KeySet, shift: Bool = false, role: KeyMeanings.Role?, note: String? = nil) {
            self.label = label
            self.keys = keys
            self.shift = shift
            self.role = role
            self.note = note
        }
    }

    /// The chords for `skill` in `data`, as the step introduces them. Empty when the layout has none.
    public static func chords(for skill: Skill, data: EngineData, mode: SubMode) -> [Chord] {
        let layout = data.layout
        var effective = data.shared.entries
        for (k, e) in data.dictionary(for: mode).entries { effective[k] = e }
        func byKeys(_ a: KeySet, _ b: KeySet) -> Bool { (a.count, a.bits) < (b.count, b.bits) }
        func texts(_ keep: (TextEntry) -> Bool) -> [(keys: KeySet, entry: TextEntry)] {
            effective.compactMap { k, e -> (keys: KeySet, entry: TextEntry)? in
                if case .text(let t) = e, keep(t) { return (k, t) }
                return nil
            }.sorted { byKeys($0.keys, $1.keys) }
        }
        func role(_ bank: Bank) -> KeyMeanings.Role { bank == .onset ? .onset : bank == .vowel ? .vowel : .coda }

        switch skill {
        case let .sound(bank, text):
            let keys = (layout.clusters[bank] ?? [:]).filter { $0.value == text }.map(\.key).sorted(by: byKeys)
            return keys.prefix(1).map { Chord(label: text, keys: $0, role: role(bank)) }
        case .pairs(let bank):
            return pairClusters(bank, data: data).map { Chord(label: $0.text, keys: $0.keys, role: role(bank)) }
        case .word(let w):
            return texts { $0.text == w && $0.kind != .suffix && !$0.isSnippet }.prefix(1).map {
                Chord(label: w, keys: $0.keys, role: nil)
            }
        case .ending(let s):
            return texts { $0.text == s && $0.kind == .suffix }.prefix(1).map {
                Chord(label: "-" + s, keys: $0.keys, role: .special)
            }
        case .symbol(let s), .abbreviation(let s):
            let quiet: Bool
            if case .abbreviation = skill { quiet = true } else { quiet = false }
            let all = texts { $0.text == s && !$0.isSnippet && isAbbreviation($0, mode: mode) == quiet }
            let brackets: Set<String> = ["\"", "'", "(", ")", "[", "]", "{", "}", "<", ">"]
            return all.map { k, t in
                var note: String?
                if quiet { note = "no capital after it" }
                else if all.count > 1 && t.attachRight != t.attachLeft {
                    note = brackets.contains(s) ? (t.attachRight ? "opening" : "closing")
                        : (t.attachRight ? "before a name" : "after a name")
                }
                return Chord(label: s, keys: k, role: .special, note: note)
            }
        case .command(let c):
            return effective.filter { $0.value == .command(c) }.map(\.key).sorted(by: byKeys).prefix(1).map {
                Chord(label: KeyMeanings.describe(c), keys: $0, role: .special)
            }
        case .join:
            return layout.spaceIndex.map { [Chord(label: "join", keys: KeySet([$0]), role: .space, note: "hold it with the chord")] } ?? []
        case .shiftJoin:
            return [Chord(label: "join", keys: KeySet(), shift: true, role: .space, note: "hold Shift with the chord")]
        case .space:
            return layout.spaceIndex.map { [Chord(label: "space", keys: KeySet([$0]), role: .space, note: "alone")] } ?? []
        case .spell:
            return layout.spellIndex.map { [Chord(label: "spell", keys: KeySet([$0]), role: .spell, note: "+ the key printed with the letter")] } ?? []
        case .capitalLetter:
            let m = KeyMeanings(data: data, mode: mode)
            guard let s = layout.spellIndex, let c = m.capitalKey else { return [] }
            return [Chord(label: "capital", keys: KeySet([s, c]), role: .spell, note: "+ the letter")]
        case .digits:
            return [Chord(label: "0 – 9", keys: KeySet(), role: .number, note: "the number row")]
        case .newLine:
            return [Chord(label: "new line", keys: KeySet(), role: nil, note: "the Return key")]
        }
    }

    /// A small teaching list. Exhaustive pair tables belong in Reference, not a first introduction.
    public static func introductionChords(for skill: Skill, at index: Int, data: EngineData) -> [Chord] {
        guard steps.indices.contains(index) else { return [] }
        guard case .pairs(let bank) = skill else {
            return chords(for: skill, data: data, mode: steps[index].mode)
        }
        let known = taught(through: index, data: data)
        let preferred = bank == .onset ? ["th", "sh", "st"] : ["nd", "te", "me"]
        let available = pairClusters(bank, data: data).filter { cluster in
            cluster.singles.allSatisfy { known.contains(.sound(bank, $0)) }
        }.sorted {
            let left = preferred.firstIndex(of: $0.text) ?? preferred.count
            let right = preferred.firstIndex(of: $1.text) ?? preferred.count
            return (left, $0.text, $0.keys.bits) < (right, $1.text, $1.keys.bits)
        }
        let role: KeyMeanings.Role = bank == .onset ? .onset : bank == .vowel ? .vowel : .coda
        return available.prefix(3).map { Chord(label: $0.text, keys: $0.keys, role: role) }
    }

    // MARK: The course

    private static func start(_ s: String...) -> [Skill] { s.map { .sound(.onset, $0) } }
    private static func vowel(_ s: String...) -> [Skill] { s.map { .sound(.vowel, $0) } }
    private static func end(_ s: String...) -> [Skill] { s.map { .sound(.coda, $0) } }
    private static func words(_ s: String...) -> [Skill] { s.map { .word($0) } }
    private static func endings(_ s: String...) -> [Skill] { s.map { .ending($0) } }
    private static func symbols(_ s: String...) -> [Skill] { s.map { .symbol($0) } }

    public static let units: [Unit] = [
        Unit(title: "Syllables", steps: [
            Step(id: "first-chord", title: "Your first chord",
                 intro: "Tap the right ⌥ Option key to turn chord typing on: the menu bar shows English. Press "
                    + "the start, vowel and end together, then release every key before the next chord. "
                    + "KeyChord puts the space before each word.",
                 new: start("s", "h") + vowel("a") + end("t"),
                 text: "a hat sat at a hat sat"),
            Step(id: "first-ends", title: "t at the start, n at the end",
                 intro: "The left hand starts a word; the right hand ends it. Add t at the start and n at the "
                    + "end. Leave out any part the word doesn't need.",
                 new: start("t") + end("n"),
                 text: "a tan hat an at sat tan"),
            Step(id: "vowels", title: "The left thumb vowels",
                 intro: "The left thumb plays a, o and e on the bottom row. Add o and e to the letters you know.",
                 new: vowel("o", "e"),
                 text: "he set ten on a hot hat"),
            Step(id: "right-thumb-vowels", title: "i, u and I",
                 intro: "The right thumb plays i and u. The i key alone types the word “I”.",
                 new: vowel("i", "u") + words("I"),
                 text: "I sit in a tin hut in it on a sun hat"),
            Step(id: "home-row", title: "r, f and d",
                 intro: "Add three starts and the end d. The left hand starts words and the right hand ends them.",
                 new: start("r", "f", "d") + end("d"),
                 text: "a red rat a fat dad I did run"),
            Step(id: "home-row-more", title: "l, g, s and undo",
                 intro: "Add l and g at the start, and s at the end. If a chord types the wrong thing, undo takes "
                    + "it back. A word can leave out parts, as in “is”.",
                 new: start("l", "g") + end("s") + [.command(.undo)],
                 text: "he is red as I let us get his gun a lot it is fun"),
            Step(id: "start-pairs", title: "Two letters at the start",
                 intro: "Two letters in a row at the start of a word: press both of their keys. The t and h keys "
                    + "make th, s and h make sh, s and t make st.",
                 new: [.pairs(.onset)],
                 text: "the hat is flat she shut the lid that is the shed then she fled the rat slid on the sled"),
            Step(id: "top-row-ends", title: "Ends on the top row",
                 intro: "The top row of the right hand ends words with y, r, m and p.",
                 new: end("y", "r", "m", "p"),
                 text: "they stay on top for a day she is shy I am her dad stop the trip from the ship"),
            Step(id: "last-keys", title: "The last single keys",
                 intro: "w and b start words from the top and bottom rows on the left. The last key of the right "
                    + "hand's bottom row is a silent e at the end of a word.",
                 new: start("w", "b", "z") + end("e"),
                 text: "we sat on the wet bus but she was hot who is that boy why is he in a tree we bet it is "
                    + "true zip it"),
            Step(id: "syllables-review", title: "Review: single-key letters",
                 intro: "Each letter mapping so far has a key of its own. Try the words without looking at the chords. "
                    + "To keep the keyboard on screen while you type in other apps, turn on the Reference "
                    + "Overlay in the KeyChord menu.",
                 new: [],
                 text: "sit hit fit set get wet sun fun run rat sat hat red bed led tip dip lip hot dot lot"),
        ]),
        Unit(title: "Letter groups", steps: [
            Step(id: "two-key-starts", title: "Letters with two keys",
                 intro: "Some letters have no key of their own at the start of a word: they take two keys, pressed "
                    + "together with the rest of the chord.",
                 new: start("m", "n", "p"),
                 text: "a man my pet put the pan on the mat no nap"),
            Step(id: "two-key-starts-ck", title: "c and k at the start",
                 intro: "Two more letters use two keys at the start: c and k.",
                 new: start("c", "k"),
                 text: "a cat can nap a kid in a cup"),
            Step(id: "more-two-key-starts", title: "y, j, v and ch",
                 intro: "Four more starts that take two keys.",
                 new: start("y", "j", "v", "ch"),
                 text: "yes we can chat in the van yet the jet is hot jam on a chip a joy"),
            Step(id: "end-pairs", title: "Two letters at the end",
                 intro: "At the end of a word too, two letters that each have a key take both keys: n and d make "
                    + "nd. With the silent e key, t makes te and m makes me.",
                 new: [.pairs(.coda)],
                 text: "and then she went home to find a card I want to rest at the camp just for a time"),
            Step(id: "two-key-ends", title: "Letters with two keys at the end",
                 intro: "At the end of a word, g, b and f take two keys.",
                 new: end("g", "b", "f"),
                 text: "the big dog dug in the fog a cab if we can"),
            Step(id: "two-key-ends-wx", title: "w and x at the end",
                 intro: "Add two more ends that take two keys: w and x.",
                 new: end("w", "x"),
                 text: "how now a fox in a box at six"),
            Step(id: "end-sounds", title: "ng, ck and ll",
                 intro: "These ends have keys of their own. Learn each mapping as a new letter group.",
                 new: end("ng", "ck", "ll"),
                 text: "sing a song the king will go back"),
            Step(id: "end-sounds-sh-ch-th", title: "sh, ch and th at the end",
                 intro: "Three familiar letter groups get different mappings at the end of a word.",
                 new: end("sh", "ch", "th"),
                 text: "wish for a fish in the bath with much joy"),
            Step(id: "end-sounds-ss-ft-ct", title: "ss, ft and ct",
                 intro: "These three ends also have mappings of their own.",
                 new: end("ss", "ft", "ct"),
                 text: "a gift in fact much less"),
            Step(id: "end-sounds-kl", title: "k and l at the end",
                 intro: "k and l end words too, alone or combined with known keys such as ke and ld.",
                 new: end("k", "l"),
                 text: "my pal in a wok I told him to make it"),
            Step(id: "blends", title: "cl, cr and pl",
                 intro: "These starts have mappings of their own. Learn their keys like single letters.",
                 new: start("cl", "cr", "pl"),
                 text: "clap and plan with a crab"),
            Step(id: "blends-pr-sk-sm", title: "pr, sk and sm",
                 intro: "Add three more starts with their own mappings.",
                 new: start("pr", "sk", "sm"),
                 text: "press it skip the small step"),
            Step(id: "blends-sn-sp-kn-qu", title: "sn, sp, kn and qu",
                 intro: "Finish this set with four starts, each with its own mapping.",
                 new: start("sn", "sp", "kn", "qu"),
                 text: "snap spin the top I know it is quick"),
            Step(id: "vowel-pairs", title: "ea, ee and oo",
                 intro: "Two vowels together take two thumb keys. Begin with ea, ee and oo.",
                 new: vowel("ea", "ee", "oo"),
                 text: "read a book at the sea we see a green tree and good food"),
            Step(id: "vowel-pairs-ou-ai", title: "ou and ai",
                 intro: "Add ou and ai with two thumb keys.",
                 new: vowel("ou", "ai"),
                 text: "out in the rain I wait"),
            Step(id: "silent-e-ends", title: "ve, ce and ge",
                 intro: "Three ends with a silent e have keys of their own.",
                 new: end("ve", "ce", "ge"),
                 text: "have a nice day give me the page I love the face of the huge cave"),
            Step(id: "two-key-review", title: "Review: letter groups",
                 intro: "Starts, vowels and ends with two keys, all together.",
                 new: [],
                 text: "sea tea read seed feed out loud food good rain tail the ship the sheep a fresh plant "
                    + "a black stamp trust and thank click and crash"),
        ]),
        Unit(title: "Endings", steps: [
            Step(id: "s-ed", title: "-s and -ed",
                 intro: "Type the word, then the ending as a chord of its own. KeyChord joins it to the word.",
                 new: endings("s", "ed"),
                 text: "the cats played and jumped the dogs wanted to look we called and needed hands"),
            Step(id: "ing-er", title: "-ing, -er, -est and -ly",
                 intro: "KeyChord fixes the spelling: it drops a silent e, doubles a letter and turns y into i "
                    + "where English does. make and -ing is making.",
                 new: endings("ing", "er", "est", "ly"),
                 text: "making tea is the nicest thing he is faster and runs slowly she tried hoping"),
            Step(id: "more-endings", title: "-ness, -ment, -able and -ful",
                 intro: "Four longer endings, each a chord of its own.",
                 new: endings("ness", "ment", "able", "ful"),
                 text: "kindness is careful a payment is readable and the darkness is restful"),
        ]),
        Unit(title: "Sentences", steps: [
            Step(id: "full-stop", title: "Full stop and comma",
                 intro: "Punctuation attaches to the word before it. After a full stop, the next word gets a "
                    + "capital by itself.",
                 new: symbols(".", ","),
                 text: "I sat on the mat. It was hot, so I had a nap. Then I went home."),
            Step(id: "capitals", title: "A capital on the next word",
                 intro: "For the first word of a text and for names, press this chord first: the next word gets a "
                    + "capital.",
                 new: [.command(.capitalizeNext)],
                 text: "Tom and Sam sat in the sun. Then Tom went home, and Sam had a nap."),
            Step(id: "questions", title: "Questions and exclamations",
                 intro: "Like the full stop, they give the next word a capital.",
                 new: symbols("?", "!"),
                 text: "Is it hot? Yes, it is! Can we go in the sea? We can!"),
            Step(id: "more-punctuation", title: "Colon, semicolon, apostrophe and hyphen",
                 intro: "The apostrophe and the hyphen join the words on both sides: it's, well-known.",
                 new: symbols(":", ";", "'", "-"),
                 text: "It's a well-made bed: the cat's bed is big; the dog's bed is not."),
            Step(id: "quotes", title: "Quotes and brackets",
                 intro: "Opening quotes and brackets attach to the word after them, closing ones to the word before.",
                 new: symbols("\"", "(", ")"),
                 text: "She said: \"Thank you.\" Tom (my pal) is here."),
        ]),
        Unit(title: "Common words", steps: [
            Step(id: "word-chords", title: "their, about and people",
                 intro: "Common words can have a chord of their own: the spell key with a few of the word's "
                    + "letters. Begin with these three words.",
                 new: words("their", "about", "people"),
                 text: "People like their work. It is about time."),
            Step(id: "word-chords-into-other-only", title: "into, other and only",
                 intro: "Learn three more useful word chords.",
                 new: words("into", "other", "only"),
                 text: "We went into the shop. We have other things to do, but only for a short time."),
            Step(id: "word-chords-over-also-after-first", title: "over, also, after and first",
                 intro: "Add four word chords, then use them together with the words you know.",
                 new: words("over", "also", "after", "first"),
                 text: "It is also the first one. We went over the top after that."),
            Step(id: "more-word-chords", title: "because, through and before",
                 intro: "Three more words have chords of their own.",
                 new: words("because", "through", "before"),
                 text: "We came through before because it was hot."),
            Step(id: "more-word-chords-between-never-every", title: "between, never and every",
                 intro: "Add three word chords and use the earlier ones again.",
                 new: words("between", "never", "every"),
                 text: "Every day we sat between them. We never went before."),
            Step(id: "more-word-chords-little-different-important-something", title: "little, different, important and something",
                 intro: "Four final word chords for this unit. Mix them with the words you have learned.",
                 new: words("little", "different", "important", "something"),
                 text: "Every little thing is different. Something is important."),
        ]),
        Unit(title: "Long words", steps: [
            Step(id: "join", title: "Join with the space bar",
                 intro: "A long word takes a chord for each part. Hold the space bar with every chord after the "
                    + "first: it joins onto the word instead of starting a new one.",
                 new: [.join],
                 text: "Anything is possible. Everybody wants something wonderful. Hello, happy people."),
            Step(id: "shift-join", title: "Join with Shift",
                 intro: "A few chords can't take the space bar: they use six keys already, or the keyboard would "
                    + "drop that combination. Hold Shift with those instead; the guide says when.",
                 new: [.shiftJoin],
                 text: "The window is open. Take the window seat."),
        ]),
        Unit(title: "Letters and numbers", steps: [
            Step(id: "spelling", title: "Spelling letters",
                 intro: "Any word can be spelled letter by letter: the spell key with the key printed with the "
                    + "letter. Add the capital key for a capital. Letters join together without spaces.",
                 new: [.spell, .capitalLetter],
                 text: "The NASA team met the BBC in the USA. It is OK."),
            Step(id: "numbers", title: "Numbers",
                 intro: "The number row types digits. Several digits go in one chord when they read left to right "
                    + "on the keyboard. Between two numbers, the space bar alone types the space.",
                 new: [.digits, .space],
                 text: "I have 2 cats and 10 dogs. It is 2026. The code is 12 34."),
        ]),
        Unit(title: "C++", steps: [
            Step(id: "cpp-mode", title: "C++ mode and keywords",
                 intro: "Code practice switches to C++ automatically. Outside practice, this chord switches "
                    + "between English and C++. Begin with three keyword chords.",
                 new: [.command(.modeSwitch)] + words("int", "return", "const"),
                 text: "int const return",
                 mode: .cpp),
            Step(id: "cpp-more-keywords", title: "auto, void and bool",
                 intro: "Three more keywords have chords of their own.",
                 new: words("auto", "void", "bool"),
                 text: "auto void bool int return",
                 mode: .cpp),
            Step(id: "cpp-symbols", title: "Assignment and arithmetic",
                 intro: "Operators get a space on each side. The semicolon attaches to the word before it.",
                 new: symbols("=", "+", "-", ";"),
                 text: "int count = 0; count = count + 1 - 2;",
                 mode: .cpp),
            Step(id: "cpp-symbols-round", title: "Comparisons and parentheses",
                 intro: "Use == to compare values. Opening parentheses attach to the next word, closing ones to "
                    + "the word before.",
                 new: symbols("==", "(", ")"),
                 text: "if (count == 2) return count;",
                 mode: .cpp),
            Step(id: "cpp-symbols-braces", title: "Braces",
                 intro: "Braces enclose a block of code. Use the operators and keywords you know inside them.",
                 new: symbols("{", "}"),
                 text: "if (count == 2) { return count; }",
                 mode: .cpp),
            Step(id: "cpp-names", title: "Names",
                 intro: "Start a name with its style, then type its words: KeyChord joins them with _ or capitals.",
                 new: [.command(.casing(.snake)), .command(.casing(.screamingSnake)), .command(.endIdentifier)],
                 text: "int max_size = MAX_VALUE;",
                 mode: .cpp),
            Step(id: "cpp-program", title: "A small program",
                 intro: "Return types a new line; the space bar alone indents it.",
                 new: [.newLine],
                 text: "int main() {\n    int count = 0;\n    return count;\n}",
                 mode: .cpp),
        ]),
    ]
}
