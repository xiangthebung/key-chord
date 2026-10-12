// Data files in ~/Library/Application Support/KeyChord/ (Req 15.1, 15.2) and persisted settings (Req 17.5).
// Only the layout, dictionaries, exceptions, probe reports and matrix scans are written. Typed text never is (Req 18.6).

import Foundation
import KeyChordCore

final class DataStore {
    let directory: URL

    init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("KeyChord", isDirectory: true)) {
        self.directory = directory
    }

    private struct CustomChordFile: Codable {
        var version = 2
        var chords: [CustomChord]
    }
    private enum CustomChordFileError: LocalizedError {
        case unsupportedVersion
        var errorDescription: String? { "These custom chords were saved by a newer version of KeyChord." }
    }
    var customChordsURL: URL { directory.appendingPathComponent("custom-chords.json") }

    func readCustomChords() throws -> [CustomChord] {
        guard FileManager.default.fileExists(atPath: customChordsURL.path) else { return [] }
        let file = try JSONDecoder().decode(CustomChordFile.self, from: Data(contentsOf: customChordsURL))
        guard (1...2).contains(file.version) else { throw CustomChordFileError.unsupportedVersion }
        return file.chords
    }

    func writeCustomChords(_ chords: [CustomChord]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let contents = try encoder.encode(CustomChordFile(chords: chords))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try contents.write(to: customChordsURL, options: .atomic)
    }

    var probeReportURL: URL { directory.appendingPathComponent("probe-report.txt") }

    func url(_ f: DataFile) -> URL { directory.appendingPathComponent(f.fileName) }

    /// Installs the bundled default of every missing file (Req 15.2). Returns problems as text.
    func installMissingDefaults() -> [String] {
        var errors: [String] = []
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return ["Could not create \(directory.path): \(error.localizedDescription)"]
        }
        upgradeUneditedDefaults()
        for f in DataFile.allCases where !FileManager.default.fileExists(atPath: url(f).path) {
            do {
                try f.defaultSource.write(to: url(f), atomically: true, encoding: .utf8)
            } catch {
                errors.append("Could not install \(f.fileName): \(error.localizedDescription)")
            }
        }
        return errors
    }

    /// FNV-1a hashes of earlier bundled defaults. An installed file that still equals one of them was never
    /// edited, so it is replaced with the current default to pick up new chords. Edited files are left alone.
    private static let supersededDefaults: [DataFile: Set<UInt64>] = [
        .english: [0x5b2e_a139_1361_9fbb,    // before the no-capital "." "?" "!" for abbreviations
                   0xc415_dd3d_5559_0747],   // before the MacBook Pro 2021 retune ("important")
        .layout: [0xe350_dc89_2b9c_947b,     // before the MacBook Pro 2021 retune (vowels on C V B / M N)
                  0xeacf_bc3a_04c7_0585],    // before the space bar joined chords
        .cpp: [0x24d4_40d2_9fd4_d2f0],       // before the MacBook Pro 2021 retune (&& || << >> ++ -- with Semicolon)
        .shared: [0x7be6_d1a5_d2ff_0e33],    // before N+M capitalized the next word (it was Equal+Backslash)
    ]

    static func fnv1a(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 {
            h ^= UInt64(b)
            h = h &* 0x0000_0100_0000_01b3
        }
        return h
    }

    /// Replaces unedited copies of earlier defaults (see `supersededDefaults`). Returns the files updated.
    @discardableResult
    func upgradeUneditedDefaults() -> [DataFile] {
        var updated: [DataFile] = []
        for (f, hashes) in Self.supersededDefaults {
            guard let text = try? String(contentsOf: url(f), encoding: .utf8), hashes.contains(Self.fnv1a(text)) else { continue }
            if (try? f.defaultSource.write(to: url(f), atomically: true, encoding: .utf8)) != nil { updated.append(f) }
        }
        return updated
    }

    func readAll() -> [DataFile: String?] {
        var out: [DataFile: String?] = [:]
        for f in DataFile.allCases { out[f] = try? String(contentsOf: url(f), encoding: .utf8) }
        return out
    }

    func readProbeReport() -> String? { try? String(contentsOf: probeReportURL, encoding: .utf8) }

    /// The keyboard's electrical matrix (see KeyboardWiring). Installed for the MacBook Pro 2021 keyboard.
    var wiringURL: URL { directory.appendingPathComponent("wiring.txt") }

    func readWiring() -> String? { try? String(contentsOf: wiringURL, encoding: .utf8) }

    /// FNV-1a hashes of earlier bundled wiring files, replaced when found unedited.
    private static let supersededWiring: Set<UInt64> = [0xbc0a_31da_d62c_04c2]   // before the Wiring Check

    /// Installs the bundled wiring for this Mac model and keyboard layout, if there is one. An installed file is
    /// replaced only when nobody edited it: an earlier bundled wiring, or the one for the other layout (earlier
    /// versions installed the ISO wiring on every MacBook Pro 2021, US keyboards included). Edited files stay.
    func installBundledWiring(model: String, keyboard: KeyboardGeometry.Kind?) {
        guard let wiring = DefaultData.bundledWiring(model: model, keyboard: keyboard) else { return }
        if let text = readWiring() {
            guard text != wiring else { return }
            let unedited = Self.supersededWiring.union(DefaultData.bundledWirings.map(Self.fnv1a))
            guard unedited.contains(Self.fnv1a(text)) else { return }
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? wiring.write(to: wiringURL, atomically: true, encoding: .utf8)
    }

    /// Matrix_Scan sweeps and analysis. Contains only key names, never typed text.
    var matrixScanURL: URL { directory.appendingPathComponent("matrix-scan.txt") }

    func readMatrixScan() -> String? { try? String(contentsOf: matrixScanURL, encoding: .utf8) }
}

final class Settings {
    private let d: UserDefaults
    init(defaults: UserDefaults = .standard) { d = defaults }

    static let keyLabelsDidChange = Notification.Name("KeyChordKeyLabelsDidChange")

    var keyLabelStyle: KeyLabelStyle {
        get { d.string(forKey: "keyLabelStyle").flatMap(KeyLabelStyle.init(rawValue:)) ?? .both }
        set {
            d.set(newValue.rawValue, forKey: "keyLabelStyle")
            NotificationCenter.default.post(name: Self.keyLabelsDidChange, object: nil)
        }
    }

    var lastSubMode: SubMode {
        get { SubMode(rawValue: d.string(forKey: "lastSubMode") ?? "") ?? .english }
        set { d.set(newValue.rawValue, forKey: "lastSubMode") }
    }

    /// Tap_Timeout in ms, default 400.
    var tapTimeoutMs: Int {
        get { let v = d.integer(forKey: "tapTimeoutMs"); return v > 0 ? v : 400 }
        set { d.set(newValue, forKey: "tapTimeoutMs") }
    }

    /// Rollover_Limit, default 6.
    var rolloverLimit: Int {
        get { let v = d.integer(forKey: "rolloverLimit"); return v > 0 ? v : 6 }
        set { d.set(newValue, forKey: "rolloverLimit") }
    }

    /// The keyboard chosen in the menu (drawn, and whose wiring is used); nil follows the type macOS reports.
    var keyboard: KeyboardGeometry.Kind? {
        get { d.string(forKey: "keyboard").flatMap(KeyboardGeometry.Kind.init(rawValue:)) }
        set { d.set(newValue?.rawValue, forKey: "keyboard") }
    }

    /// The reference overlay was on screen when KeyChord last ran.
    var overlayVisible: Bool {
        get { d.bool(forKey: "overlayVisible") }
        set { d.set(newValue, forKey: "overlayVisible") }
    }

    /// A bounded size keeps the passage and input readable without breaking the narrow workspace.
    static let practiceTextSizeRange = 16...30
    var practiceTextSize: Int {
        get {
            guard d.object(forKey: "practiceTextSize") != nil else { return 20 }
            return min(Self.practiceTextSizeRange.upperBound, max(Self.practiceTextSizeRange.lowerBound,
                                                                d.integer(forKey: "practiceTextSize")))
        }
        set { d.set(min(Self.practiceTextSizeRange.upperBound, max(Self.practiceTextSizeRange.lowerBound, newValue)),
                    forKey: "practiceTextSize") }
    }
}
