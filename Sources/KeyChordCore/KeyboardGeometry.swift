// The built-in keyboard of the MacBook Pro 2021, as drawn by the Typing Guide, the reference overlay and the
// manual: the US (ANSI) keyboard, and the Canadian French (ISO) one the wiring was measured on. Both have the
// same size, and every chord key is on both; they differ in where Grave (`) and Backslash (\) are, the shape of
// Return and left Shift, the legends, and ISO's extra key. Positions are in key units (1 unit = one letter key),
// origin top left. Standard library only.

public struct KeyboardGeometry: Sendable {
    public enum Kind: String, Sendable, CaseIterable {
        /// US: ` left of 1, \ above Return, Return one row tall, wide left Shift.
        case ansi
        /// Canadian French: § left of 1, ` between left Shift and Z, \ left of Return, L-shaped Return.
        case iso
    }

    public struct Key: Equatable, Sendable {
        /// Virtual key code; `noCode` for the unlabelled Touch ID key.
        public let code: KeyCode
        /// The printed legend.
        public let label: String
        /// The printed shifted legend, if any.
        public let shifted: String?
        public let x: Double
        public let y: Double
        public let width: Double
        public let height: Double
        /// Function row, arrows and fn: drawn with a smaller font.
        public let small: Bool
    }

    public static let width = 14.5
    public static let height = 5.7
    public static let noCode: KeyCode = 0xFFFF
    public static let returnCode: KeyCode = 36

    public static let ansi = KeyboardGeometry(.ansi)
    public static let iso = KeyboardGeometry(.iso)
    public static func of(_ kind: Kind) -> KeyboardGeometry { kind == .ansi ? ansi : iso }

    public let kind: Kind
    public let keys: [Key]
    /// The ISO Return key, 1 unit wide on the Q row and 0.75 unit on the A row (its `Key` is the bounding box);
    /// nil on ANSI, where Return is a plain key.
    public let returnOutline: [(x: Double, y: Double)]?
    private let byCode: [KeyCode: Key]

    /// For menus and the manual, e.g. "US (ANSI)".
    public var name: String { kind == .ansi ? "US (ANSI)" : "Canadian French (ISO)" }

    public func key(for code: KeyCode) -> Key? { byCode[code] }

    /// The key's printed label on this keyboard, used to describe chords ("Space" for the space bar).
    public func label(for code: KeyCode) -> String {
        if code == 49 { return "Space" }
        return byCode[code]?.label ?? "key \(code)"
    }

    private init(_ kind: Kind) {
        self.kind = kind
        keys = Self.keys(kind)
        returnOutline = kind == .iso
            ? [(13.5, 1.7), (14.5, 1.7), (14.5, 3.7), (13.75, 3.7), (13.75, 2.7), (13.5, 2.7)] : nil
        var m: [KeyCode: Key] = [:]
        for k in keys where k.code != Self.noCode { m[k.code] = k }
        byCode = m
    }

    private static func keys(_ kind: Kind) -> [Key] {
        var out: [Key] = []
        func key(_ code: KeyCode, _ label: String, _ shifted: String? = nil, x: Double, y: Double,
                 w: Double = 1, h: Double = 1, small: Bool = false) {
            out.append(Key(code: code, label: label, shifted: shifted, x: x, y: y, width: w, height: h, small: small))
        }
        func row(_ y: Double, start: Double, _ items: [(KeyCode, String, String?)]) {
            for (i, it) in items.enumerated() { key(it.0, it.1, it.2, x: start + Double(i), y: y) }
        }
        let letter: [KeyCode: String] = [12: "Q", 13: "W", 14: "E", 15: "R", 17: "T", 16: "Y", 32: "U", 34: "I",
                                         31: "O", 35: "P", 0: "A", 1: "S", 2: "D", 3: "F", 5: "G", 4: "H", 38: "J",
                                         40: "K", 37: "L", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 45: "N", 46: "M"]
        func letters(_ codes: [KeyCode]) -> [(KeyCode, String, String?)] { codes.map { ($0, letter[$0]!, nil) } }
        let digits: [(KeyCode, String, String?)] = [(18, "1", "!"), (19, "2", "@"), (20, "3", "#"), (21, "4", "$"),
                                                    (23, "5", "%"), (22, "6", kind == .ansi ? "^" : "?"), (26, "7", "&"),
                                                    (28, "8", "*"), (25, "9", "("), (29, "0", ")"), (27, "-", "_"),
                                                    (24, "=", "+")]
        let qRow = letters([12, 13, 14, 15, 17, 16, 32, 34, 31, 35])
        let aRow = letters([0, 1, 2, 3, 5, 4, 38, 40, 37])
        let zRow = letters([6, 7, 8, 9, 11, 45, 46])

        // Function row.
        key(53, "esc", x: 0, y: 0, w: 1.5, h: 0.6, small: true)
        for (i, c) in ([122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111] as [KeyCode]).enumerated() {
            key(c, "F\(i + 1)", x: 1.5 + Double(i), y: 0, h: 0.6, small: true)
        }
        key(noCode, "", x: 13.5, y: 0, h: 0.6)
        switch kind {
        case .ansi:
            row(0.7, start: 0, [(50, "`", "~")] + digits)
            key(51, "⌫", x: 13, y: 0.7, w: 1.5)
            key(48, "⇥", x: 0, y: 1.7, w: 1.5)
            row(1.7, start: 1.5, qRow + [(33, "[", "{"), (30, "]", "}"), (42, "\\", "|")])
            key(57, "⇪", x: 0, y: 2.7, w: 1.75)
            row(2.7, start: 1.75, aRow + [(41, ";", ":"), (39, "'", "\"")])
            key(returnCode, "↩", x: 12.75, y: 2.7, w: 1.75)
            key(56, "⇧", x: 0, y: 3.7, w: 2.25)
            row(3.7, start: 2.25, zRow + [(43, ",", "<"), (47, ".", ">"), (44, "/", "?")])
        case .iso:
            // On ISO keyboards the key left of 1 is kVK_ISO_Section (10).
            row(0.7, start: 0, [(10, "/", "\\")] + digits)
            key(51, "⌫", x: 13, y: 0.7, w: 1.5)
            key(48, "⇥", x: 0, y: 1.7, w: 1.5)
            row(1.7, start: 1.5, qRow + [(33, "^", "¨"), (30, "Ç", nil)])
            key(returnCode, "↩", x: 13.5, y: 1.7, w: 1, h: 2)   // drawn as the ISO L shape
            key(57, "⇪", x: 0, y: 2.7, w: 1.75)
            row(2.7, start: 1.75, aRow + [(41, ";", ":"), (39, "È", nil), (42, "À", nil)])
            key(56, "⇧", x: 0, y: 3.7, w: 1.25)
            // On ISO keyboards the key next to left Shift is kVK_ANSI_Grave (50).
            row(3.7, start: 1.25, [(50, "Ù", nil)] + zRow + [(43, ",", "'"), (47, ".", "\""), (44, "É", nil)])
        }
        key(60, "⇧", x: 12.25, y: 3.7, w: 2.25)
        key(63, "fn", x: 0, y: 4.7, small: true)
        key(59, "⌃", x: 1, y: 4.7)
        key(58, "⌥", x: 2, y: 4.7)
        key(55, "⌘", x: 3, y: 4.7, w: 1.25)
        key(49, "", x: 4.25, y: 4.7, w: 5)
        key(54, "⌘", x: 9.25, y: 4.7, w: 1.25)
        key(61, "⌥", x: 10.5, y: 4.7)
        key(123, "◀", x: 11.5, y: 4.7, small: true)
        key(126, "▲", x: 12.5, y: 4.7, h: 0.5, small: true)
        key(125, "▼", x: 12.5, y: 5.2, h: 0.5, small: true)
        key(124, "▶", x: 13.5, y: 4.7, small: true)
        return out
    }
}
