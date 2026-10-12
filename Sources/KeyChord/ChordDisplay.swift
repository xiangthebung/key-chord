/// Make whitespace visible in chord labels without changing the output text.
enum ChordDisplay {
    static func visible(_ text: String) -> String {
        var output = ""
        for character in text {
            switch character {
            case " ": output += "␣"
            case "\t": output += "⇥"
            case "\n", "\r\n", "\r": output += "↩"
            default: output.append(character)
            }
        }
        return output
    }
}
