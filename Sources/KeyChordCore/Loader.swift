// Dictionary_Loader: loads and validates the Layout, Dictionaries and Orthography_Exceptions
// (Req 4.1, 5.10, 15). File I/O is done by the platform layer; this works on strings.

public enum DataFile: String, CaseIterable, Sendable {
    case layout, shared, english, cpp, orthography

    /// File name inside ~/Library/Application Support/KeyChord/.
    public var fileName: String {
        switch self {
        case .layout: return "layout.txt"
        case .shared: return "shared.dict"
        case .english: return "english.dict"
        case .cpp: return "cpp.dict"
        case .orthography: return "orthography.txt"
        }
    }

    public var defaultSource: String {
        switch self {
        case .layout: return DefaultData.layout
        case .shared: return DefaultData.shared
        case .english: return DefaultData.english
        case .cpp: return DefaultData.cpp
        case .orthography: return DefaultData.orthography
        }
    }
}

public struct LoadOutcome: Sendable {
    public var data: EngineData
    /// Validation problems; a file with problems was replaced by its fallback (Req 15.5).
    public var problems: [LoadProblem]
    /// Probe-report warnings (Req 5.10). They do not reject a file.
    public var warnings: [LoadProblem]
    /// Chords the keyboard's wiring says it drops (edits only: the bundled defaults' own known drops are not
    /// repeated). They do not reject a file either.
    public var droppedChords: [LoadProblem] = []
    /// The source text actually in use for each file; the caller keeps these as "last valid".
    public var acceptedSources: [DataFile: String]
    /// Files that fell back to an earlier version or the bundled default.
    public var fallbacks: [DataFile]
}

public enum DictionaryLoader {
    /// - Parameters:
    ///   - sources: current file contents (nil if unreadable).
    ///   - lastValid: previously accepted contents; the bundled defaults are used when absent.
    public static func load(sources: [DataFile: String?], lastValid: [DataFile: String] = [:],
                            rolloverLimit: Int, probeReport: String? = nil, wiring: String? = nil) -> LoadOutcome {
        var problems: [LoadProblem] = []
        var accepted: [DataFile: String] = [:]
        var fallbacks: [DataFile] = []

        /// Tries the current source, then last valid, then the default.
        func pick<T>(_ file: DataFile, _ parse: (String) -> (T?, [LoadProblem])) -> T? {
            var candidates: [String] = []
            if let s = sources[file] ?? nil { candidates.append(s) } else {
                problems.append(LoadProblem(file: file.fileName, message: "file could not be read"))
            }
            if let lv = lastValid[file], !candidates.contains(lv) { candidates.append(lv) }
            if !candidates.contains(file.defaultSource) { candidates.append(file.defaultSource) }
            for (i, c) in candidates.enumerated() {
                let (value, p) = parse(c)
                if i == 0 { problems.append(contentsOf: p) }
                if let value {
                    accepted[file] = c
                    if i > 0 { fallbacks.append(file) }
                    return value
                }
            }
            return nil
        }

        let layout = pick(.layout) { LayoutParser.parse($0, file: DataFile.layout.fileName, rolloverLimit: rolloverLimit) }
            ?? Layout(keys: [], clusters: [:], fingerspelling: [:])
        func dict(_ f: DataFile) -> ChordDictionary {
            pick(f) { DictionaryParser.parse($0, file: f.fileName, layout: layout, rolloverLimit: rolloverLimit) }
                ?? ChordDictionary()
        }
        let shared = dict(.shared)
        let english = dict(.english)
        let cpp = dict(.cpp)
        let ortho = pick(.orthography) { OrthographyParser.parse($0, file: DataFile.orthography.fileName) } ?? [:]

        let data = EngineData(layout: layout, shared: shared, english: english, cpp: cpp, orthographyExceptions: ortho)
        var warnings: [LoadProblem] = []
        if let probeReport {
            do {
                let report = try ProbeReport.parse(probeReport)
                warnings = probeWarnings(report: report, data: data)
            } catch {
                warnings.append(LoadProblem(file: "probe-report.txt", message: "probe report could not be read"))
            }
        }
        var outcome = LoadOutcome(data: data, problems: problems, warnings: warnings, acceptedSources: accepted,
                                  fallbacks: fallbacks)
        if let wiring {
            if let w = try? KeyboardWiring.parse(wiring, layout: data.layout) {
                outcome.droppedChords = droppedChords(wiring: w, data: data, rolloverLimit: rolloverLimit)
            } else {
                outcome.droppedChords = [LoadProblem(file: "wiring.txt", message: "wiring file could not be read")]
            }
        }
        return outcome
    }

    /// Layout and dictionary chords the keyboard drops, leaving out those the bundled defaults drop too
    /// (for example capital A by fingerspelling on the MacBook Pro 2021), so only edits are reported.
    public static func droppedChords(wiring: KeyboardWiring, data: EngineData, rolloverLimit: Int) -> [LoadProblem] {
        func dropped(_ d: EngineData) -> [(file: String, chord: KeySet, label: String)] {
            allChords(d).filter { wiring.blocks($0.chord.indices.map { d.layout.keys[$0].code }) }
        }
        var defaults: [DataFile: String?] = [:]
        for f in DataFile.allCases { defaults[f] = f.defaultSource }
        let base = load(sources: defaults, rolloverLimit: rolloverLimit).data
        let known = Set(dropped(base).map { "\($0.file) \(base.layout.chordString($0.chord)) \($0.label)" })
        return dropped(data).compactMap { item in
            let entry = "\(data.layout.chordString(item.chord)) = \(item.label)"
            guard !known.contains("\(item.file) \(data.layout.chordString(item.chord)) \(item.label)") else { return nil }
            return LoadProblem(file: item.file, entry: entry, message: "this keyboard drops one of these keys when all are held")
        }
    }

    /// Every chord in the Layout (cluster subsets, fingerspelling chords) and the Dictionaries.
    public static func allChords(_ data: EngineData) -> [(file: String, chord: KeySet, label: String)] {
        let l = data.layout
        var out: [(String, KeySet, String)] = []
        for bank in Bank.allCases {
            for (k, v) in (l.clusters[bank] ?? [:]).sorted(by: { $0.key.bits < $1.key.bits }) {
                out.append((DataFile.layout.fileName, k, "[\(bank.rawValue)] \"\(v)\""))
            }
        }
        for (k, v) in l.fingerspelling.sorted(by: { $0.key.bits < $1.key.bits }) {
            var c = k
            if let s = l.spellIndex { c.insert(s) }
            out.append((DataFile.layout.fileName, c, "[fingerspell] \"\(v)\""))
        }
        for (file, d) in [(DataFile.shared, data.shared), (.english, data.english), (.cpp, data.cpp)] {
            for (k, e) in d.entries.sorted(by: { $0.key.bits < $1.key.bits }) {
                out.append((file.fileName, k, describe(e)))
            }
        }
        return out
    }

    static func describe(_ e: Entry) -> String {
        switch e {
        case .text(let t): return "\"\(t.text)\""
        case .command(let c): return "\(c)"
        }
    }

    public static func probeWarnings(report: ProbeReport, data: EngineData) -> [LoadProblem] {
        let failed: [KeySet] = report.results.filter(\.isFailure).compactMap { data.layout.keySet(names: $0.target) }
        guard !failed.isEmpty else { return [] }
        var out: [LoadProblem] = []
        for (file, chord, label) in allChords(data) {
            if let f = failed.first(where: { chord.isSuperset(of: $0) }) {
                out.append(LoadProblem(file: file, entry: "\(data.layout.chordString(chord)) = \(label)",
                                       message: "contains \(data.layout.chordString(f)), which failed the rollover probe"))
            }
        }
        return out
    }
}
