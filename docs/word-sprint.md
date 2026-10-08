# Word Sprint

Open **Practice → Word Sprint**, or **Word Sprint…** in the menu bar.

Choose English (200 common words), English 5k (5,000 words), or English 25k (the upstream curated set of 24,141 words). The vocabularies are bundled, with their source and license in `Resources/WordLists`; tests work offline.

Time tests run for 15, 30, 60, or 120 seconds. Word tests contain 10, 25, 50, or 100 words. The first inserted character starts the clock, which continues through idle time and focus changes. Space commits a word even if it contains an error. A word test also finishes when the last word is correct, without requiring a trailing space.

**Chords** uses the same local English chord engine as the introduction, with a focus lease suspending global interception. **Keyboard** accepts ordinary typing. Right Option can toggle the local chord mode. The optional chord guide plans the next action against the active dictionary and keyboard limits; results identify guided tests and mixed input. New test (⌘Return) samples fresh words; Retry these words (⌘R) reproduces the original stream.

Metrics use five characters per standardized word:

- **WPM:** characters in correct committed words (including their spaces), plus a correct prefix of the current word, divided by five and elapsed minutes.
- **Raw WPM:** all characters currently entered, including incorrect and extra characters, divided by five and elapsed minutes. Deleted characters are excluded.
- **Accuracy:** correct inserted characters / all inserted characters. Corrections preserve the original mistake in this score. Verified chord intermediates (such as `make` before the suffix produces `making`) count as correct.
- **Consistency:** `100 × (1 − standard deviation / mean)` for characters inserted per second, clamped to 0–100. Idle seconds count; fewer than two seconds displays no score.
- **Character details:** matching, incorrect, extra, and omitted characters in attempted words. Untouched future words are excluded. The total mistake count includes corrected errors.

The final graph shows cumulative WPM and raw WPM with red error markers. These are Monkeytype-style metrics with the formulas above; consistency is defined locally. Paste, drag/drop, and bulk ordinary insertions are disabled during tests.

Only vocabulary, test length, input method, and guide preference are saved. Typed text, results, timestamps, and graph samples stay in memory for the current test and are discarded on a new test or app exit.

Validation: `scripts/test.sh --filter WordPracticeTests` and `scripts/test-practice-ui.sh`.
