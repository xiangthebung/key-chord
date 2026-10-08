// A display preference only; chord identity always uses physical key codes.

public enum KeyLabelStyle: String, CaseIterable, Sendable {
    case meaning, physical, both
}

extension KeyMeanings {
    /// A key's meaning, its printed label, or both with the printed label first.
    /// Unassigned keys keep their printed label.
    public func label(for code: KeyCode, physical: String, style: KeyLabelStyle) -> String {
        let meaning = keys[code].flatMap { $0.label.isEmpty ? nil : $0.label } ?? Self.modifiers[code]
        guard let meaning, style != .physical else { return physical }
        if style == .both && meaning != physical { return "\(physical) (\(meaning))" }
        return meaning
    }
}
