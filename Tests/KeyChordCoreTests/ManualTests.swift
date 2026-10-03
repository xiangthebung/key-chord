import Foundation
import Testing
@testable import KeyChordCore

@Suite("Manual")
struct ManualTests {
    static let html = Manual.html(data: defaults, usable: macBookLimits.usable(in: defaults.layout))

    @Test("Every example is typed with chords")
    func examplesUseChords() {
        let html = Self.html
        #expect(html.contains("class=\"example\""))
        #expect(!html.contains("” normally</span>"))
        // "thing" shows its three parts with their keys.
        #expect(html.contains("<span class=\"means onset\">th</span>"))
        #expect(html.contains("<span class=\"means vowel\">i</span>"))
        #expect(html.contains("<span class=\"means coda\">ng</span>"))
        // Long words join with the space bar.
        #expect(html.contains("<span class=\"means number\">join</span>"))
    }

    @Test("Links to every lesson, a keyboard picture, and escaped C++ symbols")
    func structure() {
        let html = Self.html
        for i in Lessons.all.indices { #expect(html.contains("href=\"keychord://lesson/\(i)\"")) }
        #expect(html.contains("href=\"keychord://course\""))
        #expect(html.contains("<svg class=\"keyboard\""))
        #expect(html.contains("&amp;&amp;"))                        // the && operator
        #expect(!html.contains("<span class=\"out\"><<"))
        // Everything the keyboard picture says comes from the layout: the d key alone adds "ed".
        #expect(html.contains(">-ed</text>"))
    }

    /// Writes the manual to a file for a look in a browser: KEYCHORD_MANUAL_OUT=/path/manual.html.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["KEYCHORD_MANUAL_OUT"] != nil))
    func writeForReview() throws {
        let path = try #require(ProcessInfo.processInfo.environment["KEYCHORD_MANUAL_OUT"])
        try Self.html.write(toFile: path, atomically: true, encoding: .utf8)
    }
}
