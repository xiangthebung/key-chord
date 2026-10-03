# Requirements Document

## Introduction

KeyChord is a macOS menu-bar app that adds chord typing to the MacBook built-in keyboard. Tapping Option switches between normal typing and chord typing. In chord typing, the user presses several keys together and releases them, and that set of keys produces a syllable, word, symbol, or code snippet. There are two chord modes: English, which uses a spelling-based (orthographic) theory, and C++, which has its own dictionary, spacing rules, and identifier casing.

The design assumes the built-in keyboard reports at most 6 non-modifier keys at once, and that modifier keys (Shift, Control, Option, Command) do not count toward that limit. KeyChord consists of a thin macOS Platform_Layer (event interception, suppression, and output synthesis) and a platform-independent Chord_Engine that can be tested without macOS. The layout and dictionaries are user-editable data files, so the vocabulary can grow after the first version.

First version scope: rollover probe, chord engine, English basics (syllable composition, fingerspelling, briefs for common words, punctuation, suffixes), and C++ basics (symbols, keywords, snippets, identifier casing).

Out of scope for the first version:

- Phonetic (steno-style) theory.
- Dictionary entries spanning several chords, and retroactive rewriting of earlier output.
- Generating dictionaries from word lists.
- Dictionary entries that press keys such as Return, Tab, or arrows.
- Snippets with more than one cursor stop.
- Switching modes automatically based on the frontmost app.
- First-up chord detection (only all-up is supported).
- Tested layouts for keyboards other than the US ANSI MacBook built-in keyboard.

Known limitations:

- Undo is exact only for text KeyChord emitted. Editor features such as auto-closing brackets, auto-indent, and autocomplete can add or change characters, and undo cannot account for them.
- While Secure_Input is on, macOS hides keystrokes from KeyChord, so chord typing is unavailable.
- Apps that handle synthesized Unicode text poorly (some terminals, remote desktop clients, and games) may not receive output correctly.
- The keyboard may block specific key combinations below 6 keys. The Rollover_Probe exists to find them.

## Glossary

- **KeyChord**: The macOS menu-bar application specified in this document.
- **Platform_Layer**: The macOS-specific part of KeyChord. It intercepts keyboard and mouse events, passes or suppresses them, and applies Output_Actions to the focused application.
- **Chord_Engine**: The platform-independent part of KeyChord. It receives key events and produces Output_Actions. It has no dependency on macOS frameworks.
- **Event_Router**: Platform-independent logic that decides, for each keyboard event, whether it is passed through, suppressed, or sent to the Chord_Engine.
- **Dictionary_Loader**: The component that loads and validates the Layout, Dictionaries, and Orthography_Exceptions.
- **Output_Action**: One instruction from the Chord_Engine: insert text, delete N characters before the cursor, delete N characters after the cursor, or move the cursor left or right by N characters.
- **Synthetic_Event**: An event posted by the Platform_Layer to carry out an Output_Action, tagged so KeyChord can recognize it.
- **Normal_Mode**: The keyboard behaves as if KeyChord were not running.
- **Chord_Mode**: Chord_Keys are interpreted as chords. Chord_Mode has two sub-modes, English_Mode and Cpp_Mode.
- **English_Mode**: The Chord_Mode sub-mode for English prose.
- **Cpp_Mode**: The Chord_Mode sub-mode for C++ code.
- **Option_Tap**: A press and release of the right Option key, completed within Tap_Timeout, with no non-modifier key held when Option was pressed and no other key, modifier, or mouse button pressed before Option was released.
- **Tap_Timeout**: The longest Option press that still counts as an Option_Tap. Default 400 ms, configurable.
- **Chord_Key**: A key that the Layout assigns a chord role.
- **Pass_Through_Key**: Any key that is neither a Chord_Key nor a modifier. In the default Layout this includes Escape, Tab, Return, Delete, Forward Delete, the arrow keys, and the function keys.
- **Chord**: The set of Chord_Keys pressed from the moment the first Chord_Key goes down until all Chord_Keys are up, plus a Join flag recording whether the Space_Key was among its keys or the Join_Modifier was held at any point.
- **Rollover_Limit**: The maximum number of non-modifier keys the keyboard is assumed to report at once. Default 6, configurable.
- **Layout**: A data file that maps logical key names to macOS virtual key codes, assigns each Chord_Key to a Bank or a Special_Key role, and contains the Cluster_Tables and the Fingerspelling_Table.
- **Bank**: A group of Chord_Keys with one role: Onset_Bank (starting consonants, left hand), Vowel_Bank (vowels, thumbs on C, V, B, N, M), Coda_Bank (ending consonants, right hand), or Number_Bank (number row).
- **Special_Key**: A Chord_Key with a role other than letters or digits. The default Layout has a Spell_Key and the Space_Key.
- **Spell_Key**: A Special_Key that makes a Chord produce a single fingerspelled letter.
- **Space_Key**: The space bar. Pressed alone it outputs a literal space. Pressed with other Chord_Keys it sets the Chord's Join flag, so the thumbs join syllables into one word.
- **Join_Modifier**: Either Shift key, held at any point during a Chord. Like the Space_Key, it attaches the Chord's output to the previous output without a space; it is for Chords that cannot take the Space_Key (one key over the Rollover_Limit, or a combination the keyboard drops).
- **Cluster_Table**: A per-Bank table that maps subsets of that Bank's keys to letter strings, for example a pair of Onset_Bank keys producing "st".
- **Syllable_Composition**: Producing text by concatenating a Chord's Onset_Bank, Vowel_Bank, and Coda_Bank clusters, in that order.
- **Fingerspelling_Table**: A table that maps key subsets to single letters, used together with the Spell_Key.
- **Dictionary**: A data file that maps Chords, written as sets of logical key names, to Entries. There is a Shared_Dictionary used in both sub-modes, an English_Dictionary, and a Cpp_Dictionary.
- **Entry**: The translation of a Chord. It is either text with optional formatting flags (attach-left, attach-right, word-attach, glue, capitalize-next, Word_Output or Symbol_Output kind, Cursor_Marker), or a command (Undo, Mode_Switch, Capitalize_Next, Snippet_Exit, a Casing_Mode, End_Identifier).
- **Attach-left**: A formatting flag: no space is inserted before this output.
- **Attach-right**: A formatting flag: no space is inserted before the next output.
- **Word-attach**: A formatting flag: no space is inserted before this output when the previous output is a Word_Output.
- **Glue**: A formatting flag on fingerspelled letters and digits. Consecutive glued outputs join without a space.
- **Brief**: An Entry that maps one Chord to a whole word or phrase.
- **Word_Output**: Output produced by Syllable_Composition, fingerspelling, digits, or an Entry marked as a word.
- **Symbol_Output**: Output from an Entry marked as a symbol, such as operators, punctuation, and snippets.
- **Output_Context**: What the Chord_Engine knows about its recent output: the text it emitted since the last Context_Reset (bounded by the Undo_History), whether the next output needs a leading space, pending capitalization, the active Casing_Mode, and the position of the most recent Snippet.
- **Context_Reset**: An event after which KeyChord can no longer trust what it knows about the text around the cursor. Requirement 9 lists the triggers and effects.
- **Undo_History**: A stack of records, each describing one translated Chord's effect on the text, the cursor, and the Output_Context.
- **Suffix_Entry**: An Entry that attaches a suffix such as "s", "ed", or "ing" to the previous word, using Orthography_Rules.
- **Orthography_Rules**: Spelling rules applied when attaching a suffix.
- **Orthography_Exceptions**: A data file of word and suffix pairs with their correct result. It overrides the Orthography_Rules.
- **Casing_Mode**: An identifier style in Cpp_Mode: snake_case, camelCase, PascalCase, or SCREAMING_SNAKE_CASE.
- **Snippet**: An Entry whose text contains a Cursor_Marker.
- **Cursor_Marker**: A marker inside Entry text that shows where the cursor ends up after the text is inserted.
- **Untranslatable_Chord**: A Chord that no Entry, fingerspelling, digit rule, or Syllable_Composition can translate.
- **Rollover_Probe**: A diagnostic window for testing which key combinations the keyboard registers.
- **Probe_Report**: A file containing the results of a Rollover_Probe session.
- **Secure_Input**: A macOS state, turned on by password fields and some apps, in which event taps do not receive keyboard events.
- **Mode_Indicator**: The KeyChord menu-bar item.

## Requirements

### Requirement 1: Modes and the Option toggle

**User Story:** As a user, I want to switch between normal typing and chord typing by tapping Option, so that I can change how I type without leaving the keyboard.

#### Acceptance Criteria

1. WHEN KeyChord launches, THE KeyChord SHALL start in Normal_Mode.
2. WHEN an Option_Tap occurs in Normal_Mode, THE KeyChord SHALL switch to Chord_Mode in the most recently used sub-mode, or in English_Mode if no sub-mode has been used before.
3. WHEN an Option_Tap occurs in Chord_Mode, THE KeyChord SHALL switch to Normal_Mode.
4. THE KeyChord SHALL accept only the right Option key for an Option_Tap. The left Option key stays a plain modifier.
5. IF another key, another modifier, or a mouse button is pressed between an Option press and its release, THEN THE KeyChord SHALL not treat the release as an Option_Tap.
6. IF a non-modifier key is held when Option is pressed, THEN THE KeyChord SHALL not treat that press as the start of an Option_Tap.
7. IF Option is held longer than Tap_Timeout, THEN THE KeyChord SHALL not treat the release as an Option_Tap.
8. THE Platform_Layer SHALL pass Option press and release events through to the focused application in every mode, so that Option combinations such as Option+letter keep working.
9. WHEN a Mode_Switch chord completes in Chord_Mode, THE Chord_Engine SHALL switch from English_Mode to Cpp_Mode, or from Cpp_Mode to English_Mode.
10. WHEN the mode changes, THE KeyChord SHALL discard any in-progress Chord and perform a Context_Reset.

### Requirement 2: Event interception and pass-through

**User Story:** As a user, I want KeyChord to take over only the keys it needs, so that shortcuts, navigation, and normal typing keep working.

#### Acceptance Criteria

1. WHILE in Normal_Mode, THE Platform_Layer SHALL pass every keyboard event through unmodified.
2. WHILE in Chord_Mode, THE Platform_Layer SHALL suppress the press, release, and auto-repeat events of Chord_Keys so that they do not reach the focused application.
3. WHILE in Chord_Mode, THE Platform_Layer SHALL pass the events of Pass_Through_Keys and modifier keys through unmodified.
4. WHILE in Chord_Mode, WHEN a key is pressed while Command, Control, or Option is held, THE Platform_Layer SHALL pass the key event through unmodified and SHALL not add the key to a Chord.
5. THE Platform_Layer SHALL handle each key release the same way it handled the matching key press (passed or suppressed), even if the mode changed in between, so that no application sees a key stuck down.
6. THE Platform_Layer SHALL identify keys by macOS virtual key code, so that chords depend on physical key position and not on the active keyboard layout or input source.
7. THE Platform_Layer SHALL tag every Synthetic_Event, and SHALL pass tagged events through without sending them to the Chord_Engine.
8. IF macOS disables the event tap, THEN THE Platform_Layer SHALL re-enable it, discard any in-progress Chord, and perform a Context_Reset.
9. THE Platform_Layer SHALL not perform file I/O, network I/O, or other blocking work while handling an intercepted event.

### Requirement 3: Chord detection

**User Story:** As a user, I want a chord to be every key I press before I let go, so that I do not have to press keys at exactly the same instant.

#### Acceptance Criteria

1. WHILE in Chord_Mode, WHEN a Chord_Key is pressed and no Chord is in progress, THE Chord_Engine SHALL start a new Chord containing that key.
2. WHILE a Chord is in progress, WHEN a Chord_Key is pressed, THE Chord_Engine SHALL add it to the Chord, including when other keys of the Chord have already been released.
3. WHEN the last held Chord_Key of an in-progress Chord is released, THE Chord_Engine SHALL complete the Chord and translate it.
4. THE Chord_Engine SHALL produce the same Output_Actions for a Chord regardless of the order in which its keys were pressed and released.
5. THE Chord_Engine SHALL ignore auto-repeat events.
6. WHILE a Chord is in progress, WHEN the Join_Modifier is pressed or already held, or the Space_Key is one of several Chord_Keys, THE Chord_Engine SHALL set the Chord's Join flag.
7. THE Chord_Engine SHALL not count the Join_Modifier toward the Rollover_Limit. The Space_Key counts like any other key.
8. IF Command, Control, or Option is pressed while a Chord is in progress, THEN THE Chord_Engine SHALL discard the Chord without output.
9. IF a Pass_Through_Key is pressed while a Chord is in progress, THEN THE Chord_Engine SHALL discard the Chord without output.
10. IF the Chord_Engine receives a release for a key it did not record as pressed, THEN THE Chord_Engine SHALL ignore the release.
11. IF the Platform_Layer detects that none of the keys of an in-progress Chord are physically held, THEN THE Chord_Engine SHALL discard the Chord without output.

### Requirement 4: Layout and rollover limit

**User Story:** As a user, I want a layout built for the MacBook built-in keyboard and its 6-key rollover, so that every chord I need registers reliably.

#### Acceptance Criteria

1. THE Dictionary_Loader SHALL read the Layout from a data file that maps logical key names to macOS virtual key codes, assigns each Chord_Key to a Bank or a Special_Key role, and contains the Cluster_Tables and the Fingerspelling_Table.
2. THE default Layout SHALL target the US ANSI MacBook built-in keyboard, with the Onset_Bank under the left hand, the Vowel_Bank on the C, V, B, N, and M keys for the thumbs, the Coda_Bank under the right hand, and the Number_Bank on the number row.
3. THE default Layout SHALL make the space bar the Space_Key, so that the thumbs can join a Chord to the previous output without moving the hands. THE default Shared_Dictionary SHALL put Capitalize_Next on the two right-thumb vowel keys, N and M, for the same reason.
4. THE default Layout SHALL not assign Caps Lock, Fn/Globe, Command, Control, Option, or Shift as Chord_Keys.
5. THE KeyChord SHALL use a configurable Rollover_Limit with a default of 6.
6. THE default Layout and default Dictionaries SHALL contain no Chord that needs more than Rollover_Limit non-modifier keys, counting Special_Keys.
7. THE default Cluster_Tables SHALL be arranged so that the largest key subset in the Onset_Bank table, the largest in the Vowel_Bank table, and the largest in the Coda_Bank table add up to no more than Rollover_Limit, so that every Syllable_Composition Chord fits within the limit.
8. WHEN the user selects Show Layout from the menu, THE KeyChord SHALL display a reference of the active Layout that shows each key's Bank or role and the contents of the Cluster_Tables and Fingerspelling_Table.

### Requirement 5: Rollover probe

**User Story:** As a user, I want to test which key combinations my built-in keyboard actually registers, so that I can avoid chords my hardware drops.

#### Acceptance Criteria

1. WHEN the user opens the Rollover_Probe from the menu, THE Rollover_Probe SHALL show a window that displays, in real time, every key and modifier currently registered as held.
2. WHILE the Rollover_Probe window is open, THE Rollover_Probe SHALL display the largest number of non-modifier keys observed held at the same time.
3. WHILE the Rollover_Probe window has keyboard focus, THE KeyChord SHALL not interpret key events as Chords or Option_Taps, and SHALL keep probed keystrokes from reaching other applications.
4. WHEN the user starts a guided test, THE Rollover_Probe SHALL present target key combinations one at a time, taken from a source the user selects: every key subset in the Cluster_Tables and Fingerspelling_Table, every Chord in the active Dictionaries, or a user-chosen number of randomly sampled Syllable_Composition Chords that use exactly Rollover_Limit keys.
5. WHEN all keys are released during a guided test, THE Rollover_Probe SHALL compare the registered keys with the target, and record the result as passed, as failed with the missing keys listed, or as extra with the unexpected keys listed.
6. WHEN a guided test result is extra, THE Rollover_Probe SHALL let the user either retry the combination or record it as a ghosting failure.
7. WHEN the user saves the results, THE Rollover_Probe SHALL write a Probe_Report containing the observed maximum and every tested combination with its result.
8. THE Probe_Report SHALL contain only key names, results, and timestamps, and SHALL not contain typed text.
9. FOR ALL Probe_Reports, writing a report and reading it back SHALL produce an equivalent report.
10. WHEN a Probe_Report is present, THE Dictionary_Loader SHALL warn about each Chord in the Layout or Dictionaries whose keys include every key of a combination recorded as failed.

### Requirement 6: Chord translation

**User Story:** As a user, I want each chord translated by predictable rules, so that I can tell what a chord will produce.

#### Acceptance Criteria

1. WHEN a Chord completes, THE Chord_Engine SHALL form a lookup key from the Chord's keys, excluding the Space_Key when other Chord_Keys are present (it sets the Join flag instead), and SHALL apply the Join flag to the result as formatting.
2. WHEN a Chord consists only of the Space_Key, THE Chord_Engine SHALL output a literal space that is attach-left and attach-right.
3. WHEN the lookup key has an Entry in the Dictionary of the active sub-mode, THE Chord_Engine SHALL use that Entry.
4. WHEN the lookup key has no Entry in the active sub-mode's Dictionary but has one in the Shared_Dictionary, THE Chord_Engine SHALL use the Shared_Dictionary Entry.
5. WHEN the lookup key has no Entry and contains the Spell_Key, THE Chord_Engine SHALL output the letter that the Fingerspelling_Table maps to the remaining keys, with Glue.
6. WHEN the lookup key has no Entry and contains only Number_Bank keys, THE Chord_Engine SHALL output the digits of those keys in left-to-right keyboard order, with Glue.
7. WHEN the lookup key has no Entry and contains only Onset_Bank, Vowel_Bank, and Coda_Bank keys, THE Chord_Engine SHALL apply Syllable_Composition.
8. IF a Chord produces no output under criteria 2 to 7, THEN THE Chord_Engine SHALL treat it as an Untranslatable_Chord, produce no text, add no Undo_History record, and signal the Mode_Indicator.
9. THE Chord_Engine SHALL apply fingerspelling, digits, and Syllable_Composition in both English_Mode and Cpp_Mode.

### Requirement 7: Syllable composition

**User Story:** As a user, I want to spell a syllable with one chord, so that I can write words that are not in any dictionary.

#### Acceptance Criteria

1. WHEN Syllable_Composition is applied, THE Chord_Engine SHALL output the Onset_Bank cluster, then the Vowel_Bank cluster, then the Coda_Bank cluster, each looked up in its Bank's Cluster_Table by the Chord's keys in that Bank.
2. WHEN a Chord has no keys in a Bank, THE Chord_Engine SHALL use an empty string for that Bank.
3. IF a Chord's keys in a Bank are not a key subset listed in that Bank's Cluster_Table, THEN THE Chord_Engine SHALL treat the Chord as an Untranslatable_Chord.
4. THE Chord_Engine SHALL treat composed syllables as Word_Output.
5. THE default Onset_Bank and Coda_Bank Cluster_Tables SHALL each include every consonant letter.
6. THE default Vowel_Bank Cluster_Table SHALL include at least "a", "e", "i", "o", "u", "ea", "ee", "oo", and "ou".
7. THE default Onset_Bank Cluster_Table SHALL include at least "bl", "br", "ch", "cl", "cr", "dr", "fl", "fr", "gl", "gr", "pl", "pr", "sh", "sk", "sl", "sm", "sn", "sp", "st", "sw", "th", "tr", and "wh".
8. THE default Coda_Bank Cluster_Table SHALL include at least "ch", "ck", "ct", "ft", "ld", "ll", "lt", "mp", "nd", "ng", "nk", "nt", "rd", "rt", "sh", "ss", "st", and "th".

### Requirement 8: Fingerspelling, digits, and common words

**User Story:** As a user, I want to type any letter or number and the most common words quickly, so that I am never stuck on a word the system does not know.

#### Acceptance Criteria

1. THE default Layout SHALL let every letter a to z be fingerspelled, in lowercase and in uppercase, with a single Chord of at most Rollover_Limit keys including the Spell_Key.
2. THE default Layout SHALL let every digit 0 to 9 be typed with a single Number_Bank key.
3. WHEN a Glue output directly follows another Glue output, THE Chord_Engine SHALL join them without a space.
4. THE default English_Dictionary and Cluster_Tables SHALL let each of the 100 most frequent English words be written with a single Chord, through either Syllable_Composition or a Brief.
5. THE default English_Dictionary SHALL provide a Brief for the word "I" that outputs an uppercase "I".

### Requirement 9: Spacing, capitalization, and context resets

**User Story:** As a user, I want words spaced and capitalized automatically, so that I only have to chord the content.

#### Acceptance Criteria

1. THE Chord_Engine SHALL insert a single space before each output, except when it is the first output since a Context_Reset, the previous output is attach-right, the current output is attach-left, the current output is word-attach and the previous output is a Word_Output, the Chord's Join flag is set, or both the previous and current outputs have Glue.
2. WHILE in English_Mode, WHEN a sentence-ending Entry (".", "?", or "!") is output, THE Chord_Engine SHALL capitalize the first letter of the next Word_Output.
3. WHEN a Capitalize_Next chord completes, THE Chord_Engine SHALL capitalize the first letter of the next Word_Output.
4. WHILE in Cpp_Mode, THE Chord_Engine SHALL not capitalize automatically after sentence-ending punctuation.
5. THE default English_Dictionary SHALL provide Entries for the period, comma, question mark, exclamation mark, colon, semicolon, apostrophe, hyphen, opening and closing double quotes, and opening and closing parentheses.
6. THE default English_Dictionary SHALL mark the period, comma, question mark, exclamation mark, colon, semicolon, closing quote, and closing parenthesis as attach-left, the apostrophe and hyphen as attach-left and attach-right, and the opening quote and opening parenthesis as attach-right.
7. WHEN the mode changes, a Pass_Through_Key is pressed in Chord_Mode, a mouse button is pressed, the frontmost application changes, Secure_Input turns on or off, or macOS disables the event tap, THE KeyChord SHALL perform a Context_Reset.
8. WHEN a Context_Reset occurs, THE Chord_Engine SHALL clear the Undo_History, end any Casing_Mode, forget the previous word for Orthography_Rules, forget the most recent Snippet, and omit the leading space of the next output.
9. WHEN a Context_Reset occurs, THE Chord_Engine SHALL keep any pending capitalization.
10. WHILE Caps Lock is on, WHEN a Chord completes, THE Chord_Engine SHALL output the text that Chord types in uppercase, including suffixes, fingerspelled letters, and snippets, and SHALL use the uppercase text for cursor placement and undo.

### Requirement 10: English suffixes

**User Story:** As a user, I want to add endings like "ing" and "ed" with their own chord, so that I can build word forms without a separate brief for each one.

#### Acceptance Criteria

1. WHEN a Suffix_Entry is output, THE Chord_Engine SHALL attach it to the previous word without a space.
2. WHEN a Suffix_Entry is attached and the word and suffix pair appears in the Orthography_Exceptions, THE Chord_Engine SHALL replace the word with the listed result and SHALL not apply the Orthography_Rules.
3. WHEN a suffix beginning with "e" is attached to a word ending in "e", THE Chord_Engine SHALL drop the word's final "e" (agree + ed → agreed).
4. WHEN a suffix beginning with a vowel is attached to a word ending in a consonant followed by "e", THE Chord_Engine SHALL drop the word's final "e" (make + ing → making).
5. WHEN a suffix not beginning with "i" is attached to a word ending in a consonant followed by "y", THE Chord_Engine SHALL change the "y" to "i", and SHALL use "es" in place of the suffix "s" (try + ed → tried, try + s → tries, try + ing → trying).
6. WHEN the suffix "s" is attached to a word ending in "s", "x", "z", "ch", or "sh", THE Chord_Engine SHALL attach "es" instead (box + s → boxes).
7. WHEN a suffix beginning with a vowel is attached to a word that has exactly one group of vowels (a, e, i, o, u), where that group is a single vowel followed by a single final consonant other than "w", "x", or "y", THE Chord_Engine SHALL double the final consonant (stop + ing → stopping).
8. THE Chord_Engine SHALL apply the Orthography_Rules case-insensitively and SHALL keep the case of every letter it does not change.
9. IF the previous word is unknown because of a Context_Reset, THEN THE Chord_Engine SHALL attach the suffix unchanged.
10. THE default English_Dictionary SHALL provide Suffix_Entries for at least "s", "ed", "ing", "er", "est", "ly", "ness", "ment", "able", and "ful".
11. THE default Orthography_Exceptions SHALL include corrections for common words the rules get wrong, including be + ing → being, begin + ing → beginning, and tie + ing → tying.

### Requirement 11: Undo

**User Story:** As a user, I want one chord that removes exactly what my last chord did, so that I can fix mistakes without counting characters.

#### Acceptance Criteria

1. THE default Shared_Dictionary SHALL contain an Undo chord that works in both English_Mode and Cpp_Mode.
2. WHEN the Undo chord completes, THE Chord_Engine SHALL reverse the most recent Undo_History record by removing the text that chord inserted on both sides of the cursor, restoring any characters it deleted, and returning the cursor to its earlier position.
3. WHEN the Undo chord completes, THE Chord_Engine SHALL restore the Output_Context to its state before the undone chord.
4. THE Chord_Engine SHALL keep at least the 100 most recent records in the Undo_History, and SHALL reverse one record per Undo chord.
5. IF the Undo_History is empty, THEN THE Chord_Engine SHALL produce no output and signal the Mode_Indicator.
6. THE Chord_Engine SHALL not add Undo chords to the Undo_History.
7. FOR ALL sequences of N Chords (N ≤ 100) that each produce output with no Context_Reset in between, applying their Output_Actions to a text buffer and then applying N Undo chords SHALL restore the original text and cursor position.

### Requirement 12: C++ symbols and spacing

**User Story:** As a C++ programmer, I want chords for operators and punctuation with code-aware spacing, so that I can write expressions without fixing spaces by hand.

#### Acceptance Criteria

1. THE default Cpp_Dictionary SHALL provide Entries for `::`, `->`, `.`, `,`, `;`, `:`, `?`, `=`, `==`, `!=`, `<`, `>`, `<=`, `>=`, `+`, `-`, `*`, `/`, `%`, `+=`, `-=`, `*=`, `/=`, `++`, `--`, `&&`, `||`, `!`, `&`, `|`, `^`, `~`, `<<`, `>>`, `#`, `(`, `)`, `[`, `]`, `{`, and `}`.
2. THE default Cpp_Dictionary SHALL provide separate Entries for the binary and the unary or declarator forms of `*`, `&`, and `-`, for the prefix and postfix forms of `++` and `--`, and for `<` and `>` as comparison operators and as template brackets.
3. THE default Cpp_Dictionary SHALL format binary operators (assignment, compound assignment, comparison, arithmetic, logical, bitwise, and shift) with a single space on each side.
4. THE default Cpp_Dictionary SHALL format `::`, `->`, and `.` as attach-left and attach-right.
5. THE default Cpp_Dictionary SHALL format `(`, `[`, and the template `<` as word-attach and attach-right.
6. THE default Cpp_Dictionary SHALL format `)`, `]`, the template `>`, `,`, `;`, and postfix `++` and `--` as attach-left.
7. THE default Cpp_Dictionary SHALL format unary `!`, `~`, `*`, `&`, and `-`, prefix `++` and `--`, and `#` as attach-right.
8. WHILE in Cpp_Mode, THE Chord_Engine SHALL separate consecutive Word_Outputs with a single space, subject to the rules in Requirement 9.
9. THE Chord_Engine SHALL take all C++ spacing behavior from Entry flags, so that the user can change the spacing style by editing the Cpp_Dictionary.

### Requirement 13: C++ keywords and snippets

**User Story:** As a C++ programmer, I want single chords for keywords and common constructs, so that boilerplate costs one stroke.

#### Acceptance Criteria

1. THE default Cpp_Dictionary SHALL provide single-Chord Entries for at least `auto`, `bool`, `break`, `case`, `char`, `class`, `const`, `constexpr`, `continue`, `default`, `delete`, `double`, `else`, `enum`, `false`, `float`, `int`, `namespace`, `new`, `nullptr`, `override`, `private:`, `protected:`, `public:`, `return`, `sizeof`, `static`, `struct`, `template`, `this`, `true`, `typename`, `unsigned`, `using`, `virtual`, `void`, and `std::`.
2. THE default Cpp_Dictionary SHALL mark plain keywords as Word_Output, and SHALL mark Entries containing symbols (such as `std::` and `public:`) as Symbol_Output.
3. THE default Cpp_Dictionary SHALL format `std::` as attach-right.
4. THE default Cpp_Dictionary SHALL provide Snippets for at least `#include <|>`, `#include "|"`, `static_cast<|>(`, `std::vector<|>`, `template <typename |>`, `if (|)`, `for (|)`, `while (|)`, `switch (|)`, `"|"`, and `'|'`, where `|` is the Cursor_Marker.
5. WHEN a Snippet is output, THE Chord_Engine SHALL insert its text without the Cursor_Marker and then move the cursor to the marker's position.
6. WHEN an output directly follows a Snippet, THE Chord_Engine SHALL insert it at the cursor without a leading space.
7. WHEN the Snippet_Exit chord completes and no Context_Reset has occurred since the most recent Snippet, THE Chord_Engine SHALL move the cursor to the end of that Snippet's text, including any text typed inside it.
8. IF no Snippet has been output since the last Context_Reset, THEN THE Chord_Engine SHALL treat the Snippet_Exit chord as an Untranslatable_Chord.

### Requirement 14: C++ identifier casing

**User Story:** As a C++ programmer, I want to type multi-word identifiers in the casing style I need, so that names like getUserName or max_size come out right.

#### Acceptance Criteria

1. THE default Cpp_Dictionary SHALL provide a chord to start each Casing_Mode (snake_case, camelCase, PascalCase, and SCREAMING_SNAKE_CASE), and an End_Identifier chord.
2. WHEN a Casing_Mode chord completes, THE Chord_Engine SHALL start a new identifier in that Casing_Mode.
3. WHILE snake_case is active, THE Chord_Engine SHALL lowercase each Word_Output and join it to the identifier with "_".
4. WHILE SCREAMING_SNAKE_CASE is active, THE Chord_Engine SHALL uppercase each Word_Output and join it to the identifier with "_".
5. WHILE camelCase is active, THE Chord_Engine SHALL lowercase the first letter of the identifier's first word, uppercase the first letter of each later word, and join words with no separator.
6. WHILE PascalCase is active, THE Chord_Engine SHALL uppercase the first letter of every word and join words with no separator.
7. WHILE a Casing_Mode is active, THE Chord_Engine SHALL treat a run of consecutive Glue outputs as one word, and SHALL append a word made only of digits with no separator.
8. THE Chord_Engine SHALL apply the normal spacing rules of Requirement 9 before the first word of an identifier.
9. WHEN a Symbol_Output is output, the End_Identifier chord completes, or a Context_Reset occurs while a Casing_Mode is active, THE Chord_Engine SHALL end the Casing_Mode before handling that output.

### Requirement 15: Dictionary files and validation

**User Story:** As a user, I want the layout and vocabulary in files I can edit, so that I can grow and tune the system over time.

#### Acceptance Criteria

1. THE Dictionary_Loader SHALL load the Layout, the Shared_Dictionary, the English_Dictionary, the Cpp_Dictionary, and the Orthography_Exceptions from user-editable files in `~/Library/Application Support/KeyChord/`.
2. WHEN one of these files is missing from that folder at launch, THE KeyChord SHALL install the bundled default version of it.
3. THE Dictionary format SHALL express each Chord as a set of logical key names from the Layout, and each Entry as text with the formatting flags or as a command, as defined in the Glossary.
4. WHEN loading, THE Dictionary_Loader SHALL validate every file and report each problem with its file name and Entry: malformed syntax, unknown key names, Chords that need more than Rollover_Limit non-modifier keys, duplicate Chords within one Dictionary, Entries with more than one Cursor_Marker, and Cluster_Tables that break the limit in Requirement 4.
5. IF a file fails validation, THEN THE KeyChord SHALL keep using its last valid version (or the bundled default at launch) and show the problems to the user.
6. WHEN the user selects Reload Dictionaries, THE Dictionary_Loader SHALL reload and validate all files without restarting KeyChord.

### Requirement 16: Output emission

**User Story:** As a user, I want chord output to appear in any app exactly as intended, so that the result does not depend on my keyboard settings.

#### Acceptance Criteria

1. WHEN the Chord_Engine produces Output_Actions, THE Platform_Layer SHALL apply them to the focused application in order, using Delete key events for deleting before the cursor, Forward Delete key events for deleting after the cursor, Left and Right Arrow key events for cursor movement, and Unicode text events for inserting text.
2. THE Platform_Layer SHALL insert text as Unicode, independent of the active keyboard layout and Caps Lock state, and SHALL report the Caps Lock state with each key event so that the Chord_Engine can apply it (Requirement 9.10).
3. THE Platform_Layer SHALL clear all modifier flags on every Synthetic_Event, so that held modifiers such as the Join_Modifier do not change the output.
4. THE Platform_Layer SHALL apply the outputs of successive Chords in the order the Chords completed, including when a Chord completes while earlier output is still being emitted.
5. THE Platform_Layer SHALL begin emitting a Chord's output within 20 ms of the Chord completing under normal system load.
6. THE Chord_Engine SHALL count characters for deletion and cursor movement as extended grapheme clusters.

### Requirement 17: Menu-bar app and settings

**User Story:** As a user, I want to see the current mode at a glance and reach every control from the menu bar, so that I always know how my keys will behave.

#### Acceptance Criteria

1. THE KeyChord SHALL run as a menu-bar application without a Dock icon, on macOS 14 or later.
2. THE Mode_Indicator SHALL show the current mode (Normal, English, or C++), and SHALL update within 100 ms of a mode change.
3. THE KeyChord menu SHALL provide items to toggle Chord_Mode, select English_Mode or Cpp_Mode, open the Rollover_Probe, show the Layout reference, reload the dictionaries, open the dictionary folder, show permission status, and quit.
4. WHEN the Chord_Engine signals an Untranslatable_Chord or an empty Undo_History, THE Mode_Indicator SHALL show a brief visual indication.
5. WHEN KeyChord launches, THE KeyChord SHALL restore the last used sub-mode, Tap_Timeout, and Rollover_Limit from the previous session.

### Requirement 18: Permissions, Secure Input, privacy, and fail-safe

**User Story:** As a user, I want KeyChord to be safe to run all the time, so that it never locks my keyboard or leaks what I type.

#### Acceptance Criteria

1. WHEN KeyChord launches without the Accessibility permission (the only one an active event tap needs; Input Monitoring is shown for information but not required), THE KeyChord SHALL explain which permission is missing and why it is needed, and SHALL offer to open the matching System Settings pane.
2. WHILE a required permission is missing, THE KeyChord SHALL stay in Normal_Mode, refuse to enter Chord_Mode, and show the missing permission on the Mode_Indicator.
3. WHEN a missing permission is granted, THE KeyChord SHALL detect it within 2 seconds and start intercepting events, or tell the user to relaunch KeyChord if macOS requires it.
4. WHILE Secure_Input is on, THE Mode_Indicator SHALL show that chord typing is unavailable, and normal typing SHALL continue to work.
5. WHEN Secure_Input turns off, THE KeyChord SHALL resume the mode that was active before it turned on.
6. THE KeyChord SHALL keep typed text and Chord history in memory only, and SHALL not write them to disk or to logs. The Typing Guide may save aggregate per-chord practice counts and timings locally, without text, individual event sequences, or timestamps.
7. THE KeyChord SHALL not make network connections.
8. IF the Chord_Engine or the Platform_Layer encounters an unexpected internal error, THEN THE KeyChord SHALL switch to Normal_Mode and pass all events through.

### Requirement 19: Engine testability

**User Story:** As the developer, I want the chord logic separated from macOS, so that I can test it thoroughly, including with property-based tests.

#### Acceptance Criteria

1. THE Chord_Engine and the Event_Router SHALL be built as a Swift module with no dependency on macOS frameworks.
2. THE Chord_Engine SHALL be deterministic: the same Layout, Dictionaries, and sequence of input events SHALL always produce the same Output_Actions.
3. THE test suite SHALL include a text buffer simulator that applies Output_Actions, used to verify the properties in Requirements 3, 11, and 14.
4. FOR ALL sequences of keyboard events in Normal_Mode that contain no Option_Tap, THE Event_Router SHALL decide to pass every event through.
5. FOR ALL Chords, THE Chord_Engine SHALL produce the same Output_Actions for every ordering of the Chord's key presses and releases.

### Requirement 20: Learning aids

**User Story:** As a new user, I want to see what each key means, get the chords for exactly what I still have to type, and read a manual with practice texts, so that I can learn chording without trial and error.

#### Acceptance Criteria

1. THE Typing Guide's keyboard SHALL label each Chord_Key with what it stands for in the current sub-mode (its sound in a syllable, its digit, or what it does alone), colored by bank, with the printed legend in a corner, and SHALL label the Space_Key and Shift as joining and the right Option key as the chord-typing toggle.
2. FOR the current chord, THE Typing Guide SHALL show what each group of its keys stands for: the start, vowel and end of a syllable; the Spell_Key, capital key and letter; an ending; a word; a symbol; or a command.
3. WHEN the typed text matches the passage but does not end where a planned step ends, for example after part of a word and Delete, THE Typing Guide SHALL plan the chords for the rest of the line from that point, put the Output_Context where that plan starts, and show the chords for what is left of the current word.
4. THE KeyChord SHALL provide a manual, opened from the menu, whose keyboard picture, tables and example chords come from the active Layout and Dictionaries and are checked with the Chord_Engine.
5. THE manual and the Typing Guide SHALL offer practice lessons, each of which can be typed with chords only on the default Layout, on any keyboard and on the MacBook Pro 2021 keyboard.
6. THE KeyChord SHALL provide a Reference Overlay, toggled from the menu and restored at launch, that floats above other apps without taking keyboard focus and shows the keyboard labelled as in criterion 1, the sounds that take several keys, and the endings, punctuation, word chords and commands of the current sub-mode.
7. WHILE chord typing is on, THE Reference Overlay SHALL show the keys held and what the in-progress Chord would type or do if released, read the way the Chord_Engine translates it, including which group of keys makes it an Untranslatable_Chord. WHILE chord typing is off, THE Reference Overlay SHALL not show or keep the keys pressed.
8. THE KeyChord SHALL provide a course, run in the Typing Guide, of short steps grouped in units, each introducing a few sounds, words, symbols or commands shown with their keys from the active Layout and Dictionaries, with a text to type. THE KeyChord SHALL remember the steps finished and resume at the next one.
9. EVERY course step's text SHALL be typed with chords only on the default Layout, on any keyboard and on the MacBook Pro 2021 keyboard, SHALL use only what the course has introduced up to that step, and SHALL use what the step introduces.
10. THE Typing Guide SHALL offer a persistent Recall mode that hides chord formulas, key meanings, target highlights, and course references until Show Hint is requested for the current step. Advancing SHALL hide answers again.
11. THE Typing Guide SHALL save aggregate attempts, mistakes, assisted attempts, and recall timing per chord and mode. Normal typing, shortcuts, error correction, and inactive practice SHALL not count. Long pauses SHALL not affect timing. Review Weak Chords SHALL build a repeatable drill containing the available chords ranked by recent mistakes and recall time, checked against the active dictionaries and keyboard limits.
12. THE Typing Guide SHALL cap the practice keyboard's size, offer a collapsible reference legend, and show the router's actual chord-typing state beside the input, including unavailable or mismatched modes.
