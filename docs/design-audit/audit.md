**KeyChord — product, learning, and chord-design audit**  
October 5, 2026 · Prioritize first-time chord typists, while retaining an efficient path for experienced users.

KeyChord has a strong underlying idea: a compositional spelling system, a native Mac experience, and guidance that adapts to the keyboard. The biggest improvement would be to make successful learning the organizing principle of the product. Today it is easier to tell that someone finished a passage than that they can remember, comfortably execute, and transfer its chords to real writing.

The recommendation is to preserve the core theory, repair misleading learning signals, and simplify the practice loop before changing large numbers of combinations. Cosmetic polish will help, but clearer physical-key instructions and dependable feedback will have more immediate value.

This audit combines direct use of the built app, inspection of the curriculum and interaction behavior, and reproducible measurements of the bundled mappings. It is a heuristic product audit, not a usability study or a claim of measured ergonomic superiority. Source changes were already present before the audit. These findings and the measurement JSON are a **baseline before the follow-up implementation**. Small changes were handled directly; larger changes were delegated to GPT-6.1 Sol at High. See [the implementation plan](/Users/xiang/Downloads/PROJECTS/opus-5.5/key-chord/docs/design-audit/implementation-plan.md) for the current implementation status and remaining work. The inspected app binary is timestamped October 4 at 10:58, while the practice-window source at audit time was timestamped 11:15 that day. Direct observations and source-derived findings are distinguished below because the two are not necessarily identical.

Live flows examined: course overview and lesson navigation, the first lesson, guided and recall presentation, ordinary-text completion, topic discovery, listening and its answer reveal, weak-chord review, C++ practice, and full-screen versus ordinary-window layout. The manual, first-launch permissions, global-mode behavior, import detection, and review scheduling were inspected in source. A clean first installation, physical multi-key reliability, prolonged typing comfort, VoiceOver speech, high-contrast appearance, and real-editor transfer were not tested.

**What should be preserved**

- Learn and Practice are understandable top-level destinations. Keep them rather than adding a large dashboard.
- The course already constrains generated exercises to taught skills and checks whether the keyboard can register the planned chords.
- Meaningful alternatives are accepted when they produce the same output and context. Preserve this flexibility.
- Recall mode, on-demand hints, listening practice, error undo, and weak-chord review are useful foundations.
- The keyboard reference, floating overlay, and spelling/suffix model create a coherent product identity.
- Aggregate local performance storage and avoidance of stored passages are valuable privacy choices. Spaced review can be added without recording users' writing.

**Findings, ordered by importance**

1. **Passage completion is being presented as skill achievement. Priority: high. Evidence: reproduced in the app and confirmed in source.**

   On the already-completed first lesson, with chord typing explicitly off, pasting the displayed passage produced “Lesson complete,” 18/18 words, 708 WPM, and zero mistakes. The matching-text condition marks a lesson done without requiring chord input or successful recall. This need not be malicious: ordinary typing, paste, or following every hint can all inflate the apparent achievement.

   Keep ordinary text editing available, but classify the result correctly. Track “Practiced,” “Recalled,” and “Retained” separately. Pasted or normally typed content must not qualify for a chord-speed record or recall credit. A hinted success should count as useful guided practice. A short unassisted check on new examples should establish recall; a later check should establish retention. Do not make course exploration dependent on perfect scores.

   Acceptance: pasting a lesson cannot create a chord mastery result or WPM record; guided practice cannot silently become recall credit; legitimate alternative chord sequences remain accepted. Source: [completion logic](/Users/xiang/Downloads/PROJECTS/opus-5.5/key-chord/Sources/KeyChord/TypingGuideWindow.swift), [course completion](/Users/xiang/Downloads/PROJECTS/opus-5.5/key-chord/Sources/KeyChord/TypingGuideWindow.swift).

2. **Default hints obscure the physical keys a beginner must press. Priority: high. Evidence: observed and confirmed in defaults.**

   The first lesson displayed “s + a + t,” with explanations equivalent to “s → s, a → a, t → t.” Its physical keys are S + C + J. The C++ prompt for “int” displayed “m + spell + u,” because the system relabeled the physical I and N keys by their syllable meanings. For mnemonic word chords, this actively hides the mnemonic.

   Make Both the beginner default, with the printed key visually primary and its output secondary: **S → s · C → a · J → t**. Identify Start, Vowel, and End in text as well as color. Explain that the left T and right J can both represent t in different positions. Use detected keyboard legends consistently, including the actual printed label of the spell key on ISO keyboards. Keep meaning-only labels as an advanced preference.

   Acceptance: a first-time user can locate all keys for “sat” without opening Settings, interpreting a color legend, or guessing whether “a” means the A key. Source: [label default](/Users/xiang/Downloads/PROJECTS/opus-5.5/key-chord/Sources/KeyChord/Storage.swift), [label formatting](/Users/xiang/Downloads/PROJECTS/opus-5.5/key-chord/Sources/KeyChordCore/KeyLabelStyle.swift).

3. **Weak-chord review can turn spelling fragments into apparent vocabulary. Priority: high. Evidence: reproduced in the app.**

   The generated review contained “possible.”, “try”, “looke”, “neede”, and “want”, repeated three times. A fragment can be valid chord output, but an unlabeled fragment presented as an ordinary word is a confusing learning target. Repeating the same ordered material also makes passage familiarity easier to mistake for flexible recall.

   Prefer valid words or short phrases that require the weak chord. For word-building practice, show the whole intended word and label any intermediate state explicitly. Keep an intentional fragment drill as a separate exercise type with clear framing. Interleave weak items with known ones and vary their context on subsequent rounds.

   Acceptance: ordinary word practice does not produce unlabeled nonword fragments; suffix drills show a meaningful complete-word transformation. Source: [review candidate construction](/Users/xiang/Downloads/PROJECTS/opus-5.5/key-chord/Sources/KeyChordCore/ChordPractice.swift).

4. **The “small lessons” promise breaks at the curriculum's difficult points. Priority: high. Evidence: measured from the current course.**

   There are 34 lessons in eight units. One lesson introduces 11 new skills, and several introduce 10. The pair lessons render 16 onset examples or 30 coda examples because their introductory lists expand the full pair table. That list can include component mappings not yet taught, even though the exercise planner correctly filters the actual practice.

   Start with two or three new mappings per learning episode as a hypothesis to test, not a universal cognitive limit. Teach one generative pair rule with two examples and let the learner discover another. Reveal additional examples only after success. Move exhaustive tables to Reference. Split ten-word brief lessons into small, useful sets.

   Acceptance: every visible introductory example uses known components or explicitly introduces them; each episode has one clear objective and a short unassisted check. Source: [curriculum](/Users/xiang/Downloads/PROJECTS/opus-5.5/key-chord/Sources/KeyChordCore/Course.swift), [introductory chord expansion](/Users/xiang/Downloads/PROJECTS/opus-5.5/key-chord/Sources/KeyChord/TypingGuideWindow.swift). Exact counts are in [measurements](/Users/xiang/Downloads/PROJECTS/opus-5.5/key-chord/docs/design-audit/chord-measurements.json).

5. **Recall is a manual display preference rather than a learning progression. Priority: high. Evidence: observed controls and source.**

   With hints and From memory are useful, but the preference persists across lessons. Recall mode hides the lesson introduction as well as the answer, so a learner can encounter new material without its teaching context. The product does not itself take the learner from demonstration to assisted execution to recall.

   Keep the objective and short instructions visible in every mode. Hide only answer-bearing content. Make the lesson sequence “See it → Try it → Recall it → Use it.” Allow experienced learners to test out. Offer a hint after difficulty without framing it as failure, then revisit the same mapping later without the hint.

   Retrieval practice improved delayed retention in the cited experiments; those experiments used prose material, not chord typing. Applying the principle here is a design hypothesis to validate with chord learners. [Roediger and Karpicke, 2006](https://www.psychologicalscience.org/journals/psychological-science/j.1467-9280.2006.01693.x/). Source: [recall presentation](/Users/xiang/Downloads/PROJECTS/opus-5.5/key-chord/Sources/KeyChord/TypingGuideWindow.swift).

6. **Review ranks weakness but does not account for forgetting over time. Priority: high. Evidence: source-confirmed.**

   Current ranking combines recent error rate, recent time, and the lifetime proportion of hints. Stored chord records have no last-reviewed date or due date. Three rounds in one sitting are not the same experience as returning after a delay. Historical hints can also keep influencing priority after the user improves.

   Add per-skill last-practiced date, recent unassisted success, and a next-review date. Show a small “Review due” action beside Continue. Review timing should adapt to demonstrated recall. An initial next-day / several-days / week schedule is a product experiment, not a scientifically optimal schedule. Use recent hint dependency rather than a permanent penalty.

   Spacing research supports revisiting material after delays and shows that useful gaps depend on the intended retention interval; it does not establish a fixed best schedule for KeyChord. [Cepeda et al., 2008](https://pubmed.ncbi.nlm.nih.gov/19076480/). Source: [performance and priority](/Users/xiang/Downloads/PROJECTS/opus-5.5/key-chord/Sources/KeyChordCore/ChordPractice.swift).

7. **The practice screen spends too much space before the action. Priority: high. Evidence: observed in full-screen and ordinary-window views.**

   Navigation, a large lesson card, practice-mode controls, a passage card, a repeated current word, chord explanation, input card, statistics, and keyboard form a tall stack. In the ordinary window, the keyboard extends below the visible area. Long passages have their own scroll area inside the scrolling workspace. Beginners must move their attention between several representations.

   Keep current target, input, current chord, and keyboard together. Collapse the lesson introduction after it is understood. Use a compact passage strip with nearby context, not a second dominant text surface. Put the optional reference in a side pane at wide sizes and a disclosure at narrow sizes. Provide a focus layout for fluent practice.

   Acceptance: the current word, typed result, and required keys remain visible together at the supported laptop-window size. Long imports should not push core controls out of reach. A deliberately narrow window may scroll, but the current task should remain understandable.

8. **The personalized action has lower prominence than the exercise catalog. Priority: medium. Evidence: observed.**

   Practice leads with a large listening card, followed by eight large topic cards. Review weak chords and Use your own text sit at the bottom. This asks learners to diagnose their own needs while placing the only personalized recommendation last.

   Lead with one suggested session: “Review the chords you found difficult” or “Continue your next lesson,” including an estimated duration once the app can estimate it. Place free practice below in compact rows or smaller cards. Keep custom text easy to find for users who want real writing.

   Use Listen and type as an optional mode, not the default recommendation for every learner. Rename “weak chords” to “Chords to revisit” or “Personal review” if user testing finds the current wording discouraging.

9. **Readiness is too quiet, and recovery is too generic. Priority: high for beginners. Evidence: observed status; error handling inspected in source.**

   The app shows an editable input while chord typing is off. The instruction to tap right Option is secondary text at the bottom of that box. Errors generally say to fix the text with Delete or the undo chord. They do not explain whether the learner missed a key, added one, merged two chords, or selected a combination the hardware cannot register.

   Put a visible “Start chord practice” action and mode indicator near the target. Teach pressing and releasing every key with a tiny interactive exercise. If a known combination is unreliable, offer a tested alternative and label the explanation as a hardware-model prediction when appropriate. Do not infer a dropped key with certainty from one failed attempt.

   Use precise, local feedback such as “You pressed S + C; add J for the ending t,” when the captured input supports it. Keep Delete and undo discoverable, and teach recovery through an actual correction task rather than explanatory text alone. Apple's feedback guidance supports clear state and correction information near the affected interaction. [Apple: Feedback](https://developer.apple.com/design/human-interface-guidelines/feedback?changes=_9).

10. **First-run permission setup precedes an opportunity to understand the benefit. Priority: medium. Evidence: source-derived, not tested on a clean profile.**

    Launch creates a menu-bar app and prompts for Accessibility when required. The permission explanation is concrete and includes a useful privacy statement. However, the first-run path does not present a short, progressive introduction to the typing technique.

    Add a local practice sandbox that can teach the first chord before global keyboard interception is enabled. Request Accessibility when the user chooses to type in other applications, explain why, then verify the result with a short practice task. This requires implementing local composition, rather than merely hiding the permission dialog. Keep advanced keyboard scans out of onboarding.

    Apple's onboarding guidance favors short, interactive, contextual teaching and deferring nonessential setup. [Apple: Onboarding](https://developer.apple.com/design/human-interface-guidelines/onboarding?changes=_7). Source: [launch](/Users/xiang/Downloads/PROJECTS/opus-5.5/key-chord/Sources/KeyChord/AppController.swift), [permission explanation](/Users/xiang/Downloads/PROJECTS/opus-5.5/key-chord/Sources/KeyChord/AppController.swift).

11. **The mental model mixes spelling, sounds, key positions, and commands. Priority: medium. Evidence: source and visible wording.**

    This is an orthographic system, but the UI repeatedly calls its pieces “sounds.” A two-key combination can spell one letter, a pair of letters, or a command. For example, physical O contributes d within a syllable but adds -ed by itself; K + L contributes ng within a syllable but adds -ing by itself. The same visible output letter can exist in both hand banks.

    Teach “Start letters / Vowels / End letters,” and explicitly distinguish “within a word chord” from “pressed alone.” Name mnemonic word chords as shortcuts. Use a worked example for each rule, rather than showing all rules simultaneously. The 10 composition-versus-dictionary differences in the measurement file are mostly intentional features, not accidental collisions.

12. **Current metrics mix different scopes. Priority: medium. Evidence: observed and source-confirmed.**

    The passage shows current progress and mistakes. The input footer also shows saved attempts, correctness, time, and assistance for the current chord. The accessibility label names that scope, but the visible numbers do not. A fresh exercise can therefore show many attempts before the learner has typed anything.

    Label historical information “Your history with this chord,” place it behind a detail disclosure during active practice, and show a clear session summary afterward. Favor unassisted accuracy, correction count, and recall latency for learning. Show WPM only for qualifying chord-generated writing and distinguish continuous writing from deliberate study. Do not penalize a learner for opening instructions or taking a break.

13. **Listening practice is not adapted to what has been taught. Priority: medium. Evidence: source-confirmed; interface observed.**

    Listening uses a shuffled vocabulary bag and validates that words are typeable, but it does not restrict prompts to learned skills. It advances continuously and defaults to one US English voice/rate. Correct completion moves to the next word after 0.55 seconds. A beginner can receive a long word that needs skills from much later in the course.

    Add “My learned chords” and “All vocabulary,” a finite session goal, replay and pacing controls, and an accessible text-recall alternative. Separate “Reveal the word” from “Reveal its chord” when listening accuracy and chord recall need separate measurement. Show a brief result before advancing, with a learner-controlled pace.

    Source: [vocabulary selection](/Users/xiang/Downloads/PROJECTS/opus-5.5/key-chord/Sources/KeyChordCore/ListeningPractice.swift), [speech configuration](/Users/xiang/Downloads/PROJECTS/opus-5.5/key-chord/Sources/KeyChord/PracticeSpeaker.swift).

14. **Hardware confidence is less visible than the strength of the compatibility claim. Priority: medium, higher when expanding device support. Evidence: source and model audit.**

    The bundled ISO wiring is based on observations from a MacBook Pro 2021; the ANSI wiring is explicitly derived rather than measured. Unknown hardware defaults to permissive planning. Four explicitly listed capital fingerspelling chords are predicted to fail by the bundled models. The loader intentionally suppresses warnings for known default failures, while the planner works around them. The manual's “never suggests” wording is therefore broader than the available hardware evidence.

    Show a compact keyboard status: tested here, predicted from a related model, or not checked. Offer a short check of relevant chords, with progress and a useful alternative when one fails. Phrase claims as “avoids combinations known to fail on this keyboard.” Keep full matrix scanning in advanced tools. Hardware problems should not look like a learner's memory failure.

15. **Accessibility has a useful baseline, but the keyboard needs a richer alternative. Priority: medium. Evidence: accessibility tree and source inspection.**

    Native controls and named actions are present. However, the keyboard is exposed as one image with a summary; learners cannot explore each key, its role, and its held/target state individually. Bank identity is strongly color-led. The design uses many small secondary labels and has no visible practice text-size control.

    Add a navigable textual chord breakdown, optional finger guidance, adjustable practice text, and announcement of meaningful results without speaking every key-state change. Ensure correct/error/required-key states differ by text or shape as well as color. Test VoiceOver, Increase Contrast, Reduced Motion, keyboard navigation, and narrow windows before making accessibility claims. The current review is not a measured contrast or WCAG conformance audit. [Apple: Color](https://developer.apple.com/design/human-interface-guidelines/color?changes=_5_2).

16. **The path from course work to everyday writing needs an explicit bridge. Priority: medium. Evidence: source-derived and observed navigation.**

    Manual, Course, Typing Guide, Show Layout, and Reference Overlay are overlapping entry points. Practice Settings contains key labels, while keyboard selection and timing live in the menu bar. Imported text selects English or C++ automatically, with no visible language override in the practice settings. C++ contributes to the same 34-lesson completion count as English.

    Use consistent names: Learn, Practice, Reference, and Settings. Put the overlay under Reference, and keyboard detection plus mode controls in Settings. Make language detection overridable for imported material. Offer C++ as an optional track. After a basic milestone, guide the learner through writing a short original sentence in a supported editor and returning after a mistake. An app's own input field cannot establish transfer to editors with auto-pairs, indentation, or different cursor behavior.

**A visual direction that makes the app more appealing**

Use a restrained native “practice studio” design: neutral background, one clear accent, fewer large outlined containers, stronger emphasis on the current word, and deliberate typography. The present product does not need decorative illustrations or more gamification to become attractive. Its distinctive visual element should be the relationship between printed keys and the letters they produce.

Two interactive concepts accompany this audit:

- **Guided studio** is the recommended beginner direction. It keeps a small lesson sequence beside a single practice surface, gives printed keys prominence, labels the role of each key, and puts the current state and feedback near the action.
- **Focus practice** is the later-stage direction. It removes the lesson scaffolding, emphasizes the word and current attempt, and reveals the key guide only when requested. Instructions remain visible when answers are hidden.

These concepts demonstrate hierarchy and disclosure; they do not implement the native app or intercept real keyboard chords. The three examples use the existing mappings: sat = S+C+J, hat = E+C+J, tan = T+C+H. They use simulated interactions and do not display measured user performance. A production version should add an expandable physical keyboard/finger view during early learning, then fade that support with demonstrated recall.

Concrete styling changes: use regular sentence case, reserve monospace for physical chords and code, keep supporting instructional text comfortable to read, shorten the lesson header, use compact progress within the task, and replace catalog-sized cards with denser rows where the content is simply a choice list. Color-coded banks can remain in the reference, with explicit role labels.

**A more effective learning sequence**

A first session should produce a small, understandable success:

1. Show what a chord does with one word and a press/release demonstration.
2. Orient the learner to the physical keys and suggested fingers. Verify release of all keys.
3. Practice a tiny set such as sat, hat, and tan, changing one component at a time.
4. Remove the answer while keeping the objective and instructions visible.
5. Include an unfamiliar but constructible word to check whether the rule transfers.
6. Teach one real correction with undo, and one switch back to ordinary typing.
7. End with a specific result: what was practiced, what was recalled, and what to revisit.

Then introduce frequent useful words, sentence punctuation, joins, suffix transformations, fingerspelling, and optional coding in small steps. Keep the course's existing capability checks. Use initial blocked practice to establish a mapping, then mix nearby alternatives and earlier material as a product experiment. Do not introduce difficult interleaving immediately to a learner who cannot yet execute the basic movement.

A possible starting criterion for “Recalled” is successful unassisted attempts in several different contexts, rather than one percentage across a copied passage. Define the criterion transparently and validate it. Avoid declaring long-term mastery on day one. “Retained” should depend on a later recall check. Hints and retries should preserve the learner's place.

**Can the combinations be more optimal? Yes, but define optimal carefully.**

The existing planner prioritizes fewer chords, then penalizes Shift and extra keys. Its base chord cost is 100, with key count added, a Shift cost of 10, and an extra Space-join cost of 2. It does not model finger conflicts, hand travel, familiarity, transition difficulty, or observed correction cost. Consequently, it can correctly choose the shortest sequence without choosing the easiest one for this learner.

The current mapping is already strong in coverage:

| Measurement | No blocking assumed | Bundled ISO wiring model | Derived ANSI wiring model |
|---|---:|---:|---:|
| Repository's 100-word test list: words typed in one chord | 100 / 100 | 99 / 100 | 99 / 100 |
| Chords to type each of those words once | 100 | 101 | 101 |
| Total key activations, including Shift | 341 | 342 | 342 |
| Words requiring normal-typing fallback | 0 | 0 | 0 |
| Chords across the 34 built-in course passages | 718 | 723 | 723 |
| Normal-typing fallback steps across those passages | 0 | 0 | 0 |

These are counts from fresh-context plans, not speed measurements. The repository labels the list as common words; this audit did not independently validate its corpus provenance. Each word appears once, so these figures are not frequency-weighted English coverage. One chord may still require several simultaneous key activations. Chord compression and physical effort are different measures.

The layout has 49 onset, 10 vowel, and 64 coda mappings. Including empty banks but excluding the empty chord yields 35,749 abstract compositions; the two bundled wiring models each predict 3,744 blocked combinations, about 10.5%. These include nonwords and dictionary overrides. This is **not** a 10.5% real-writing failure rate: the planner avoids modeled failures and can split output into safe steps.

Of 337 explicit mapping records inspected, four are predicted blocked in both bundled models: capital A, H, J, and K using Spell + Semicolon + letter. The planner already has alternatives. Teach the available alternative in context; do not present the theoretical spelling table as universally executable.

Specific ergonomic questions worth measuring:

- “you” currently uses Q+W+C+V. C+V asks the nominal left-thumb bank to activate two adjacent vowel keys. This might be comfortable with a learned bridge or roll, but should not be assumed comfortable for every hand.
- F+G for onset m, T+G for j, and R+T in the “through” brief overlap standard touch-typing finger assignments. Chording can use different fingering, so these are candidates for assessment rather than proof of impossibility.
- Uppercase fingerspelling and many briefs concentrate work around the spell key. Measure repeated right-hand load and transitions, not just individual isolated chords.
- The all-keys-up engine accepts non-simultaneous presses while another key remains held. Teach this deliberately; otherwise users may try to press everything at exactly the same instant or accidentally merge adjacent chords.

Two concrete, conservative experiments are supported by the model audit:

| Candidate | Current route on the bundled model | Experimental route | What is known |
|---|---|---|---|
| use | N, then Semicolon+Slash+Space: 2 chords, 4 key activations | Spell+U+S: 1 chord, 3 activations | Unassigned in English; predicted unblocked in both models. The same chord means “using” in C++. |
| you | Q+W+C+V: 1 chord, 4 activations | Spell+Y+O: 1 chord, 3 activations | Unassigned in both modes; predicted unblocked in both models. Avoids the double-left-thumb vowel pair, but shifts work to the right hand. |

“Spell” means the physical key assigned the Quote role; its printed legend depends on the keyboard. These are **candidates**, not proven improvements, and neither was installed. “use” has the clearer first case because it saves a chord on the modeled keyboard. “you” saves one activation but adds a learned shortcut and concentrates three keys on the right hand. Human comfort and retention must decide whether that trade is worthwhile.

A better optimization approach:

- Treat known hardware failures and invalid output/context as hard constraints.
- Optimize expected execution time plus correction time, then incorporate subjective comfort and learning cost.
- Use actual word frequency for the user's chosen domain, with separate English and C++ evaluation.
- Include the transition between successive chords, same-finger demands, thumb pairs, reach, and hand balance.
- Prefer small compatible additions over remapping learned keys. Keep mapping versions and provide migration practice when a mapping does change.
- Offer “Learning,” “Comfort,” and “Fewest strokes” planning preferences only if each produces a understandable, validated difference. Explain the suggested alternative in context instead of exposing numerical cost weights.
- Penalize changes to a user's familiar route unless the expected benefit is material. Stability itself reduces learning cost.

An initial objective can be written as frequency-weighted **execution time + expected correction time + comfort penalty + relearning cost**, with hard compatibility checks outside the score. Weights should come from observations and user preferences. The current audit cannot honestly identify a globally optimal keyboard layout.

Source: [planner costs](/Users/xiang/Downloads/PROJECTS/opus-5.5/key-chord/Sources/KeyChordCore/TypingPlanner.swift). Reproduce all count and candidate checks with [measurement script](/Users/xiang/Downloads/PROJECTS/opus-5.5/key-chord/docs/design-audit/measure-chords.swift); results are in [JSON](/Users/xiang/Downloads/PROJECTS/opus-5.5/key-chord/docs/design-audit/chord-measurements.json).
