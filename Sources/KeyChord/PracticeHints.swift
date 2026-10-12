import AppKit
import KeyChordCore

enum PracticeHints {
    /// Continuation plans can begin in the middle of a word. Keep a requested hint attached
    /// to its complete visible word, including apostrophes, hyphens and attached punctuation.
    static func wordRange(for step: TypingStep, in text: String) -> Range<Int> {
        let characters = Array(text)
        guard !characters.isEmpty else { return 0..<0 }
        let index = min(max(0, step.source.lowerBound), characters.count - 1)
        if characters[index].isWhitespace { return index..<(index + 1) }
        var start = index, end = index + 1
        while start > 0 && !characters[start - 1].isWhitespace { start -= 1 }
        while end < characters.count && !characters[end].isWhitespace { end += 1 }
        return start..<end
    }

    /// Pair lessons expand into concrete sounds; compare the taught skills in the same
    /// language so switching to C++ does not accidentally introduce the English course again.
    static func newSkills(at index: Int, data: EngineData) -> Set<Course.Skill> {
        let mode = Course.steps[index].mode
        let previous = Set(Course.steps[..<index].map(\.id))
        let before = Course.learnedSkills(completedIDs: previous, data: data, mode: mode)
        let after = Course.learnedSkills(completedIDs: previous.union([Course.steps[index].id]), data: data, mode: mode)
        return after.subtracting(before)
    }

    static func keyboardGuide(caption: NSTextField, hint: NSTextField, button: NSButton,
                              keyboard: KeyboardDiagramView) -> NSStackView {
        hint.font = .systemFont(ofSize: 13, weight: .medium)
        hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let explanation = PracticeUI.column([caption, hint], spacing: 4)
        explanation.setContentHuggingPriority(.init(1), for: .horizontal)
        explanation.setHuggingPriority(.init(1), for: .horizontal)
        let header = PracticeUI.row([explanation, button], spacing: 20)
        header.distribution = .fill
        button.setContentHuggingPriority(.required, for: .horizontal)
        explanation.leadingAnchor.constraint(equalTo: header.leadingAnchor).isActive = true
        button.trailingAnchor.constraint(equalTo: header.trailingAnchor).isActive = true
        header.heightAnchor.constraint(greaterThanOrEqualToConstant: 42).isActive = true
        return PracticeUI.column([header, keyboard], spacing: 12)
    }
}
