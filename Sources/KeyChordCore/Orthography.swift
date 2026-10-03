// Orthography_Rules for attaching suffixes (Req 10.2 - 10.8).

public enum Orthography {
    static let vowels: Set<Character> = ["a", "e", "i", "o", "u"]

    static func lower(_ c: Character) -> Character { Character(String(c).lowercased()) }
    static func isVowel(_ c: Character) -> Bool { vowels.contains(lower(c)) }
    static func isConsonant(_ c: Character) -> Bool { c.isLetter && !isVowel(c) }

    /// Returns `word` with `suffix` attached.
    /// Rules are applied case-insensitively; letters the rules do not change keep their case.
    public static func attach(word: String, suffix: String, exceptions: [String: String]) -> String {
        guard !word.isEmpty, !suffix.isEmpty else { return word + suffix }
        let lw = word.lowercased()
        let ls = suffix.lowercased()

        if let result = exceptions[lw + "+" + ls] {
            return matchCase(of: word, to: result)
        }

        var w = Array(word)
        let lwa = Array(lw)
        let s0 = ls.first!
        var sfx = suffix

        // 10.3 suffix starting with "e" on a word ending in "e": drop the word's "e".
        if s0 == "e" && lwa.last == "e" {
            w.removeLast()
            return String(w) + sfx
        }
        // 10.4 vowel suffix on consonant + "e": drop the "e".
        if isVowel(s0), lwa.count >= 2, lwa.last == "e", isConsonant(lwa[lwa.count - 2]) {
            w.removeLast()
            return String(w) + sfx
        }
        // 10.5 consonant + "y" and a suffix not starting with "i": y -> i, and "s" -> "es".
        if s0 != "i", lwa.count >= 2, lwa.last == "y", isConsonant(lwa[lwa.count - 2]) {
            let y = w.removeLast()
            w.append(y.isUppercase ? "I" : "i")
            if ls == "s" { sfx = matchSuffixCase(suffix, "es") }
            return String(w) + sfx
        }
        // 10.6 "s" after s, x, z, ch, sh: use "es".
        if ls == "s" && (lw.hasSuffix("s") || lw.hasSuffix("x") || lw.hasSuffix("z") || lw.hasSuffix("ch") || lw.hasSuffix("sh")) {
            return word + matchSuffixCase(suffix, "es")
        }
        // 10.7 one vowel group made of a single vowel followed by one final consonant (not w, x, y): double it.
        if isVowel(s0), shouldDouble(lwa) {
            w.append(w.last!)
            return String(w) + sfx
        }
        return word + sfx
    }

    static func shouldDouble(_ w: [Character]) -> Bool {
        guard w.count >= 2, w.allSatisfy(\.isLetter) else { return false }
        let last = w[w.count - 1]
        guard isConsonant(last), !["w", "x", "y"].contains(last) else { return false }
        guard isVowel(w[w.count - 2]) else { return false }
        // Exactly one vowel group, and it is the single vowel before the final consonant.
        for c in w[0..<(w.count - 2)] where isVowel(c) { return false }
        return true
    }

    /// "es" in the case of the original suffix "s"/"S".
    static func matchSuffixCase(_ original: String, _ replacement: String) -> String {
        original.first?.isUppercase == true ? replacement.uppercased() : replacement
    }

    /// Applies the capitalization pattern of `word` (all caps or initial cap) to an exception result.
    static func matchCase(of word: String, to result: String) -> String {
        let letters = word.filter(\.isLetter)
        if letters.count > 1 && letters.allSatisfy(\.isUppercase) { return result.uppercased() }
        if let f = word.first, f.isUppercase { return result.prefix(1).uppercased() + result.dropFirst() }
        return result
    }
}
