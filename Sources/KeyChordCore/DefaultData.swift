// Bundled default data files (Req 4.2, 4.3, 7.5-7.8, 8, 9.5, 9.6, 10.10, 10.11, 11.1, 12, 13, 14.1, 15.2).
// Installed into ~/Library/Application Support/KeyChord/ when missing; the user can edit them there.

public enum DefaultData {
    public static let layout = #"""
# KeyChord layout: US ANSI MacBook built-in keyboard.
#
# [keys]  NAME  KEYCODE  ROLE  [DIGIT]
# Key names are the physical key labels. Chords depend on key position (virtual key code),
# not on the active input source.
#
#   ` 1 2 3 4 5 6 7 8 9 0 - =          number row: digits (Grave, Minus, Equal are symbol keys)
#    Q W E R T | Y U I O P [ ] \        left: onset bank   right: coda bank
#    A S D F G | H J K L ; '            ' is the spell key
#     Z X C V B | N M , . /             C V B N M: vowel bank for the thumbs
#       [        space        ]         space bar: a space alone; held with a chord, joins it to the word before
#
# Largest onset (2) + vowel (2) + coda (2) cluster = 6 keys = rollover limit.

[keys]
Grave      50  onset
1          18  number 1
2          19  number 2
3          20  number 3
4          21  number 4
5          23  number 5
6          22  number 6
7          26  number 7
8          28  number 8
9          25  number 9
0          29  number 0
Minus      27  coda
Equal      24  coda
Q          12  onset
W          13  onset
E          14  onset
R          15  onset
T          17  onset
Y          16  coda
U          32  coda
I          34  coda
O          31  coda
P          35  coda
LBracket   33  coda
RBracket   30  coda
Backslash  42  coda
A           0  onset
S           1  onset
D           2  onset
F           3  onset
G           5  onset
H           4  coda
J          38  coda
K          40  coda
L          37  coda
Semicolon  41  coda
Quote      39  spell
Z           6  onset
X           7  onset
C           8  vowel
V           9  vowel
B          11  vowel
N          45  vowel
M          46  vowel
Comma      43  coda
Period     47  coda
Slash      44  coda
Space      49  space

# Onset (starting consonants), left hand. Single keys: q w h r t / l s d f g / z b (X).
[onset]
Q = "q"
W = "w"
E = "h"
R = "r"
T = "t"
A = "l"
S = "s"
D = "d"
F = "f"
G = "g"
Z = "z"
A+W = "x"
X = "b"
E+D = "c"
T+G = "j"
S+D = "k"
F+G = "m"
D+F = "n"
E+R = "p"
Z+X = "v"
Q+W = "y"
S+T = "st"
S+W = "sw"
S+A = "sl"
S+E = "sh"
T+E = "th"
W+E = "wh"
T+R = "tr"
D+R = "dr"
F+R = "fr"
G+R = "gr"
X+R = "br"
F+A = "fl"
G+A = "gl"
X+A = "bl"
W+R = "wr"
T+W = "tw"
S+R = "sp"
S+F = "sk"
D+W = "sm"
S+X = "sn"
F+W = "pl"
E+F = "pr"
D+G = "ch"
E+G = "cl"
D+T = "cr"
Q+D = "kn"
D+X = "qu"
Q+E = "ph"

# Vowels, thumbs: C = a, V = o, B = e (left thumb), M = i, N = u (right thumb).
# Placed for the MacBook Pro 2021 keyboard wiring: N and M share wires with the right-hand keys, so the
# vowels that most often come before a right-hand ending sit on the left thumb, and N+M is not used.
[vowel]
C = "a"
V = "o"
B = "e"
M = "i"
N = "u"
C+V = "ou"
B+V = "ea"
N+V = "ee"
C+N = "oo"
C+M = "ai"

# Coda (ending consonants), right hand. Single keys: y r m d p / n t k l s / e (Slash).
# Two letters that both have a key are typed with those two keys (n + t = H+J). The other pairs are placed
# so that the MacBook Pro 2021 keyboard registers them with the common vowels.
# Grave, Minus, Equal, brackets, Backslash, Comma and Period are left for dictionary chords.
[coda]
Y = "y"
U = "r"
I = "m"
O = "d"
P = "p"
H = "n"
J = "t"
K = "k"
L = "l"
Semicolon = "s"
Slash = "e"
U+Y = "ry"
H+Y = "ny"
L+Y = "ly"
U+I = "rm"
U+O = "rd"
U+H = "rn"
U+J = "rt"
U+K = "rk"
U+Slash = "re"
I+P = "mp"
I+Semicolon = "ms"
I+Slash = "me"
H+O = "nd"
L+O = "ld"
O+Semicolon = "ds"
O+Slash = "de"
H+J = "nt"
H+K = "nk"
H+Semicolon = "ns"
H+Slash = "ne"
L+J = "lt"
J+Semicolon = "st"
J+Slash = "te"
K+Semicolon = "ks"
K+Slash = "ke"
L+Semicolon = "ls"
L+Slash = "le"
P+Semicolon = "ps"
P+Slash = "pe"
Semicolon+Slash = "se"
L+U = "th"
K+L = "ng"
P+L = "ll"
I+J = "ch"
I+K = "sh"
O+K = "ck"
I+O = "ss"
Semicolon+U = "ft"
O+J = "ct"
P+K = "g"
J+P = "b"
I+L = "f"
Semicolon+Y = "v"
I+Y = "w"
Slash+Y = "x"
Y+J = "z"
H+P = "c"
J+K = "h"
O+Y = "j"
P+Y = "q"
O+P = "ve"
H+I = "ce"
K+Y = "ge"

# Fingerspelling: Quote (spell key) + the key labelled with the letter.
# Add Semicolon for the uppercase letter.
[fingerspell]
A = "a"
B = "b"
C = "c"
D = "d"
E = "e"
F = "f"
G = "g"
H = "h"
I = "i"
J = "j"
K = "k"
L = "l"
M = "m"
N = "n"
O = "o"
P = "p"
Q = "q"
R = "r"
S = "s"
T = "t"
U = "u"
V = "v"
W = "w"
X = "x"
Y = "y"
Z = "z"
A+Semicolon = "A"
B+Semicolon = "B"
C+Semicolon = "C"
D+Semicolon = "D"
E+Semicolon = "E"
F+Semicolon = "F"
G+Semicolon = "G"
H+Semicolon = "H"
I+Semicolon = "I"
J+Semicolon = "J"
K+Semicolon = "K"
L+Semicolon = "L"
M+Semicolon = "M"
N+Semicolon = "N"
O+Semicolon = "O"
P+Semicolon = "P"
Q+Semicolon = "Q"
R+Semicolon = "R"
S+Semicolon = "S"
T+Semicolon = "T"
U+Semicolon = "U"
V+Semicolon = "V"
W+Semicolon = "W"
X+Semicolon = "X"
Y+Semicolon = "Y"
Z+Semicolon = "Z"
"""#

    public static let shared = #"""
# Shared dictionary: used in English and C++ mode (after the mode's own dictionary).
# KEYS = "text" [flags]   or   KEYS = command

Backslash = undo
LBracket+RBracket = mode-switch
# Capital on the next word: the right thumb on both of its vowel keys.
N+M = capitalize-next
"""#

    public static let english = #"""
# English dictionary.
# Flags: attach-left attach-right word-attach glue cap-next word symbol suffix

# Punctuation
Period = "." attach-left cap-next symbol
Comma = "," attach-left symbol
Period+Slash = "?" attach-left cap-next symbol
Comma+Period = "!" attach-left cap-next symbol
# Quote + the same keys: no automatic capital after it, for abbreviations and dialogue ("Mr. and", "Hi?" he said).
Quote+Period = "." attach-left symbol
Quote+Period+Slash = "?" attach-left symbol
Quote+Comma+Period = "!" attach-left symbol
Semicolon+Period = ":" attach-left symbol
Semicolon+Comma = ";" attach-left symbol
Quote = "'" attach-left attach-right symbol
Minus = "-" attach-left attach-right symbol
Quote+LBracket = "\"" attach-right symbol
Quote+RBracket = "\"" attach-left symbol
LBracket = "(" attach-right symbol
RBracket = ")" attach-left symbol

# Suffixes (attach to the previous word with spelling rules)
Semicolon = "s" suffix
O = "ed" suffix
K+L = "ing" suffix
U = "er" suffix
J+Semicolon = "est" suffix
L+Y = "ly" suffix
H+Semicolon = "ness" suffix
H+J = "ment" suffix
P+H = "able" suffix
U+P = "ful" suffix

# Briefs. "I" is the i vowel key alone; most others are Quote + letters of the word.
M = "I" word
Quote+T+H = "their" word
Quote+A+B = "about" word
Quote+P+L = "people" word
Quote+I+N+T = "into" word
Quote+O+T+H = "other" word
Quote+O+N+L = "only" word
Quote+I+T+S = "its" word
Quote+O+V = "over" word
Quote+A+L = "also" word
Quote+A+F = "after" word
Quote+F+S+T = "first" word
Quote+E+V = "even" word
Quote+B+C = "because" word
Quote+D+S = "does" word
Quote+T+H+R = "through" word
Quote+B+F = "before" word
Quote+B+T = "between" word
Quote+U+N = "under" word
Quote+A+G = "again" word
Quote+N+V = "never" word
Quote+E+V+R = "every" word
Quote+L+T = "little" word
Quote+D+F = "different" word
Quote+I+M+T = "important" word
Quote+A+N = "another" word
Quote+A+R = "around" word
Quote+E+X = "example" word
Quote+S+M = "something" word
Quote+Q+N = "question" word
Quote+T+G+R = "together" word
Quote+W+O = "without" word
"""#

    public static let cpp = #"""
# C++ dictionary. Spacing comes only from these flags (Req 12.9): binary operators have no
# flags, so they get a space on each side. Quote acts like Shift on the key it is chorded with;
# Semicolon doubles an operator (&& || << >> ++ --).
# A | in text is the cursor marker; write \| for a literal pipe.

# Punctuation and member access
Period = "." attach-left attach-right symbol
Comma = "," attach-left symbol
Semicolon = ";" attach-left symbol
Semicolon+Period = ":" symbol
Semicolon+Comma = "::" attach-left attach-right symbol
Minus+Period = "->" attach-left attach-right symbol
Quote+Slash = "?" symbol

# Binary operators
Equal = "=" symbol
Quote+Equal = "==" symbol
Quote+1+Equal = "!=" symbol
Quote+Comma = "<" symbol
Quote+Period = ">" symbol
Quote+Comma+Equal = "<=" symbol
Quote+Period+Equal = ">=" symbol
Quote+Minus = "+" symbol
Minus = "-" symbol
Quote+8 = "*" symbol
Slash = "/" symbol
Quote+5 = "%" symbol
Quote+Minus+Equal = "+=" symbol
Minus+Equal = "-=" symbol
Quote+8+Equal = "*=" symbol
Slash+Equal = "/=" symbol
Quote+7+Semicolon = "&&" symbol
Quote+Backslash+Semicolon = "\|\|" symbol
Quote+7 = "&" symbol
Quote+Backslash = "\|" symbol
Quote+6 = "^" symbol
Quote+Comma+Semicolon = "<<" symbol
Quote+Period+Semicolon = ">>" symbol

# Unary, prefix and declarator forms (Comma = "before")
Quote+1 = "!" attach-right symbol
Quote+Grave = "~" attach-right symbol
Quote+8+Comma = "*" attach-right symbol
Quote+7+Comma = "&" attach-right symbol
Minus+Comma = "-" attach-right symbol
Quote+Minus+Semicolon+Comma = "++" attach-right symbol
Minus+Semicolon+Comma = "--" attach-right symbol
Quote+3 = "#" attach-right symbol

# Postfix forms (Period = "after")
Quote+Minus+Semicolon+Period = "++" attach-left symbol
Minus+Semicolon+Period = "--" attach-left symbol

# Brackets
LBracket = "(" word-attach attach-right symbol
RBracket = ")" attach-left symbol
LBracket+P = "[" word-attach attach-right symbol
RBracket+P = "]" attach-left symbol
Quote+LBracket = "{" symbol
Quote+RBracket = "}" symbol
Comma+LBracket = "<" word-attach attach-right symbol
Period+RBracket = ">" attach-left symbol

# Keywords (Quote + letters)
Quote+A+U = "auto" word
Quote+C+N = "const" word
Quote+C+X = "constexpr" word
Quote+C+T = "continue" word
Quote+D+F = "default" word
Quote+D+L = "delete" word
Quote+D+B = "double" word
Quote+E+L = "else" word
Quote+E+N = "enum" word
Quote+F+S = "false" word
Quote+F+L = "float" word
Quote+N+S = "namespace" word
Quote+N+P = "nullptr" word
Quote+O+V = "override" word
Quote+P+V = "private:" symbol
Quote+P+R = "protected:" symbol
Quote+P+B = "public:" symbol
Quote+R+T = "return" word
Quote+S+Z = "sizeof" word
Quote+S+C = "static" word
Quote+S+R = "struct" word
Quote+T+M = "template" word
Quote+T+Y = "typename" word
Quote+U+N = "unsigned" word
Quote+U+S = "using" word
Quote+V+R = "virtual" word
Quote+V+D = "void" word
Quote+S+D = "std::" attach-right symbol

# Keywords that are also plain syllables (same chord as syllable composition), and int, whose syllable
# chord i + nt is one the MacBook Pro 2021 keyboard drops
X+C+N+L = "bool" word
X+R+B+V+K = "break" word
E+D+C+Semicolon+Slash = "case" word
D+G+C+U = "char" word
E+G+C+I+O = "class" word
Quote+I+N = "int" word
D+F+B+I+Y = "new" word
T+E+M+Semicolon = "this" word
T+R+N+Slash = "true" word

# Snippets (| marks where the cursor goes)
Quote+3+Comma = "#include <|>" symbol
Quote+3+Period = "#include \"|\"" symbol
Quote+S+C+T = "static_cast<|>(" attach-right symbol
Quote+V+C = "std::vector<|>" symbol
Quote+T+M+Y = "template <typename |>" symbol
Quote+I+F = "if (|)" symbol
Quote+F+R = "for (|)" symbol
Quote+W+L = "while (|)" symbol
Quote+S+W = "switch (|)" symbol
Quote+LBracket+RBracket = "\"|\"" symbol
Quote = "'|'" symbol
RBracket+Backslash = snippet-exit

# Identifier casing (Grave + S/C/P/A), Grave alone ends the identifier
Grave+S = snake-case
Grave+C = camel-case
Grave+P = pascal-case
Grave+A = screaming-snake-case
Grave = end-identifier
"""#

    public static let orthography = #"""
# Orthography exceptions: word + suffix = result. These override the spelling rules.
be + ing = being
begin + ing = beginning
tie + ing = tying
die + ing = dying
lie + ing = lying
dye + ing = dyeing
refer + ing = referring
refer + ed = referred
prefer + ing = preferring
prefer + ed = preferred
occur + ing = occurring
occur + ed = occurred
admit + ing = admitting
admit + ed = admitted
control + ing = controlling
control + ed = controlled
quit + ing = quitting
quiz + s = quizzes
argue + ment = argument
true + ly = truly
whole + ly = wholly
due + ly = duly
day + ly = daily
say + ed = said
pay + ed = paid
lay + ed = laid
go + s = goes
do + s = does
panic + ed = panicked
picnic + ing = picnicking
"""#

    /// Wiring of the MacBook Pro 14" / 16" (2021, M1 Pro / Max) built-in keyboard, worked out from a Matrix
    /// Scan and a Wiring Check on a MacBookPro18,1 (ISO). It explains 998 of their 999 observations.
    public static let wiringMacBookPro18 = #"""
# KeyChord keyboard wiring: the electrical matrix of the built-in keyboard.
# A cell is a Layout key name, "." for an empty spot (or one not known to hold a key),
# or "?" for a key that is not a chord key (modifiers, Delete, Return, Tab, arrows...).
# Rows and columns are wires.
#
# Three keys in an L (two on a row, one of those on a column with the third) are dropped only when the
# fourth corner of the rectangle holds a key. Keys on one wire, or with no shared wire, never block.
#
# The columns follow the physical columns (1 Q A Z, 2 W S X, 3 E D C, 4 R F V, 5 T G B, 6 Y H N,
# 7 U J M, ...). The rows follow the physical rows on the right, but W R, S G, D V B and E have rows
# of their own. Columns are named after the number-row key on them.
version 1
hardware MacBookPro18,1
columns k1 k2 k3 k4 k5 k6 k7 k8 k9 k0 kEq
row num      1     2  3  4  5         6        7     8        9      0         Equal
row top      Q     .  .  .  T         Y        U     I        O      P         .
row home     A     .  .  F  .         H        J     K        L      Semicolon .
row bottom   Z     X  C  .  .         N        M     Comma    Period Slash     .
row space    Grave ?  ?  .  ?         Space    ?     ?        .      Quote     .
row bracket  .     .  ?  ?  Backslash RBracket ?     LBracket ?      ?         .
row minus    ?     ?  ?  .  .         .        ?     ?        Minus  ?         ?
row w        .     W  .  R  .         .        .     .        .      .         .
row s        .     S  .  .  G         .        .     .        .      .         .
row d        .     .  D  V  B         .        .     .        .      .         .
row e        .     .  E  .  .         .        .     .        .      .         .
"""#

    /// The same keyboard with the US (ANSI) layout: not measured. The ISO wiring above, assuming that the 46
    /// chord keys in the same place on both layouts keep their wires. Grave and Backslash are elsewhere on ANSI
    /// keyboards, so they have no place (chords with them are never predicted to drop); the spots of the ISO
    /// Grave and Backslash keys stay "?", so whatever the ISO keyboard drops is predicted to drop here too.
    public static let wiringMacBookPro18ANSI = #"""
# KeyChord keyboard wiring: the electrical matrix of the built-in keyboard.
# A cell is a Layout key name, "." for an empty spot (or one not known to hold a key),
# or "?" for a key that is not a chord key (modifiers, Delete, Return, Tab, arrows...).
# Rows and columns are wires.
#
# Three keys in an L (two on a row, one of those on a column with the third) are dropped only when the
# fourth corner of the rectangle holds a key. Keys on one wire, or with no shared wire, never block.
#
# US (ANSI) keyboard: NOT MEASURED. This is the wiring measured on the Canadian French (ISO) keyboard of the
# same MacBook Pro, assuming that the keys in the same place on both layouts keep their wires. Grave (left
# of 1 here, where ISO has the section key) and Backslash (above Return here) sit somewhere else than on ISO,
# so their place is not known and they are left out: chords with them are never predicted to drop. The spots of the
# ISO Grave and Backslash keys are kept as "?" (row space, column k1 and row bracket, column k5), so
# everything the ISO keyboard drops is predicted to drop here too. A Matrix Scan (Option-click the menu bar
# icon, Developer) on a US MacBook says how much of this holds.
version 1
hardware MacBookPro18,1 US ANSI (derived from the ISO wiring, not measured)
columns k1 k2 k3 k4 k5 k6 k7 k8 k9 k0 kEq
row num      1     2  3  4  5         6        7     8        9      0         Equal
row top      Q     .  .  .  T         Y        U     I        O      P         .
row home     A     .  .  F  .         H        J     K        L      Semicolon .
row bottom   Z     X  C  .  .         N        M     Comma    Period Slash     .
row space    ?     ?  ?  .  ?         Space    ?     ?        .      Quote     .
row bracket  .     .  ?  ?  ?         RBracket ?     LBracket ?      ?         .
row minus    ?     ?  ?  .  .         .        ?     ?        Minus  ?         ?
row w        .     W  .  R  .         .        .     .        .      .         .
row s        .     S  .  .  G         .        .     .        .      .         .
row d        .     .  D  V  B         .        .     .        .      .         .
row e        .     .  E  .  .         .        .     .        .      .         .
"""#

    /// Every wiring file KeyChord has bundled in this version, to recognize an installed one nobody edited.
    public static let bundledWirings = [wiringMacBookPro18, wiringMacBookPro18ANSI]

    /// The bundled wiring for a Mac model (`hw.model`, e.g. "MacBookPro18,3") and its keyboard layout: the
    /// 14" and 16" MacBook Pro of 2021 (MacBookPro18,1 to 18,4) with an ISO or a US (ANSI) keyboard. Nil for
    /// other Macs, and when the layout is not known (JIS, for example).
    public static func bundledWiring(model: String, keyboard: KeyboardGeometry.Kind?) -> String? {
        guard model.hasPrefix("MacBookPro18,"), let keyboard else { return nil }
        switch keyboard {
        case .iso: return wiringMacBookPro18
        case .ansi: return wiringMacBookPro18ANSI
        }
    }

    /// Wiring check for the MacBook Pro 2021 keyboard: every 3-key combination whose result the wiring
    /// above does not settle, as rounds of "hold two keys, tap these". None of them was in the first scan.
    /// - Rounds 1-28: each pair of the eight keys that never blocked (W E R S D G V B), tapping the keys that
    ///   reveal whether the pair shares a wire, and together all 56 triples of the eight.
    /// - Then one tap for every spot of the matrix used as a fourth corner but never observed.
    /// - Last: where Grave is (the one result the wiring does not explain).
    /// The last key of each round is only there to end it and is expected to register.
    public static let wiringCheckMacBookPro18 = #"""
version 1
hardware MacBookPro18,1
name 1
round W+E : Grave 1 2 3 4 5 Minus Equal R O LBracket Backslash L
round W+R : Grave 1 2 4 5 Minus Equal Backslash S O
round W+S : Grave 1 2 3 4 5 Minus Equal Q E RBracket Backslash K
round W+D : Grave 1 2 3 4 5 Minus Equal E O LBracket Backslash L
round W+G : Grave 1 2 3 4 5 Minus Equal E O RBracket Backslash L
round W+V : Grave 1 2 3 4 5 Minus Equal E O LBracket Backslash K
round W+B : 1 2 3 4 5 7 Minus Equal E Y LBracket Backslash Semicolon L
round E+R : 1 2 3 4 5 Minus Equal LBracket Backslash S Semicolon I
round E+S : Grave 1 2 3 4 5 Minus Equal I LBracket Backslash D G L
round E+D : Grave 1 2 3 4 5 Minus Equal R O LBracket Backslash G J L
round E+G : Grave 1 2 3 4 5 Minus Equal R I LBracket Backslash L V K
round E+V : Grave 1 2 3 4 5 Minus Equal R Y Backslash S J
round E+B : Grave 1 2 3 4 5 7 9 0 Minus Equal R I RBracket S L
round R+S : Grave 1 2 3 4 5 Minus Equal RBracket Backslash D G P
round R+D : Grave 1 2 3 4 5 Minus Equal W U Backslash G Semicolon V Period L
round R+G : Grave 1 2 3 4 5 Minus Equal W O LBracket Backslash V B L
round R+V : Grave 1 2 4 5 Minus Equal W Backslash S B L
round R+B : 1 2 4 5 Equal W O LBracket Backslash S D K
round S+D : Grave 1 2 3 4 5 Minus Equal W U LBracket Backslash G L
round S+G : Grave 1 2 3 4 5 Minus Equal W U RBracket Backslash V B L
round S+V : 1 2 3 4 5 Minus Equal W I LBracket Backslash D B K
round S+B : Grave 1 2 3 4 5 Minus Equal W U RBracket Backslash D L
round D+G : Grave 1 2 3 4 5 Minus Equal W Backslash V B K
round D+V : Grave 1 2 3 4 5 7 Minus Equal W E Backslash B I
round D+B : Grave 1 2 3 4 5 0 Minus Equal W E U RBracket Backslash L
round G+V : 1 2 3 4 5 Minus Equal W LBracket Backslash B Semicolon
round G+B : 1 2 3 4 5 Minus Equal W E U RBracket Backslash Semicolon L
round V+B : Grave 1 2 4 5 7 Minus Equal W E Backslash K
round 6+Space : 1 2 3 4 5 9 Equal L
round Minus+O : Q T Y U P L
round RBracket+Backslash : Y H N Space L
round 9+O : 2 3 4 Equal L
round 9+L : 2 3 5 Equal I
round T+Y : RBracket N L
round LBracket+K : A F O
round Semicolon+Slash : F O
round Minus+L : F I
round Equal+Slash : 0 L
round Equal+RBracket : 6 L
round LBracket+Comma : X L
round Grave+Space : 6 7 Y U H J N M P
"""#

    /// Follow-up check after the first Wiring Check: the 19 spots on the W, S, D and E rows that the
    /// corrected wiring uses as fourth corners without an observation. Nothing here was tested before.
    public static let wiringCheck2MacBookPro18 = #"""
version 1
hardware MacBookPro18,1
name 2
round 3+E : 1 6 7 8 9 0 Equal L
round 2+W : 6 7 8 9 0 Equal L
round 2+S : 1 9 Equal L
round 3+D : 7 9 Equal L
"""#
}
