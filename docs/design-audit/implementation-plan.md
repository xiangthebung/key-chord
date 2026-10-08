# Design audit implementation plan

Keep the existing spelling theory, chord identities, meaningful alternative routes, learned-skill filtering, and hardware constraints. Implement the following in order; the audit and measurement JSON supply the evidence.

## Implemented in this pass

- Input provenance follows UTF-16 edits, suffix replacements, and corrections in the actual AppKit practice field. Chord output plus captured attempts is required for course credit; ordinary typing, paste, and mixed final text do not qualify. Explicit planned Return/Tab keep structural credit. Deleted ordinary mistakes do not taint correctly repaired chord text. The active timer pauses on focus loss, mode changes, and settings; unassisted qualifying completion alone displays chord WPM.
- Guided practice, explicit hints, lesson detail reveals during Recall, and visible keyboard reference count as assistance. Saved course completion means **Practiced**. A complete unaided course attempt earns a separately stored **Unassisted pass**, without claiming delayed retention. Legacy completed IDs safely expand to split lessons but never create unaided passes. The aggregate chord history separately tracks recent recall and dated spaced checks.
- Missing/invalid key-label preferences default to Both; saved valid choices persist. Both labels and keyboard drawing put printed keys first. Current chord parts say Start, Vowel, and End in text. Legends use detected/selected ANSI or ISO geometry, including Spell. Shift labels use the shared meaning/physical preference.
- The course now has 52 short lessons, each with at most four explicit `Course.Skill` entries. Category skills such as spelling, digits, and pairs can cover more physical mappings. A new lesson always starts Guided even when Recall was saved. Generated exercises remain restricted to introduced/learned skills. Guided completion offers a fresh unaided retry.
- Review uses verified whole-word/phrase contexts, including suffix transformations, and ranks due aggregate records first. Course overview offers Review due alongside Continue. Badges and review selection exclude stale mappings and chords beyond current rollover/hardware limits. Records contain aggregate counts and epoch days, never passages or raw key logs.
- The active layout puts target, chord hint, typed result, and Start/Pause state together. Long passages have a bounded preview; keyboard reference, saved history, and lesson details use disclosure. Recall keeps a short objective visible and hides current chord answers until assistance is requested. New lesson teaching remains visible; understood introductions collapse.
- Start/Pause uses the existing router availability checks and displays actual permission, Secure Input, and mode state. It does not create another interception engine.
- Listening defaults to My learned chords, offers All vocabulary, and uses ten-word sessions. Correct words wait for an explicit Next word; replay is available. Show word supports practice without audio while keeping chord keys hidden, and Show answer reveals the chord answer. Either reveal counts as assistance. Finite completion shows words practiced and hints used.
- English course progress is shown separately; C++ units are labelled Optional with their own counts. The resume search stays within its current language track. Imported text now offers Auto, English, and C++ while preserving its passage, draft, selection, and input provenance. Built-in lessons keep their assigned language.
- `Manual.swift` distinguishes measured ISO wiring, derived ANSI wiring, and unchecked keyboards; it describes predicted avoidance and rollover limits.
- Regression coverage now includes native paste/ordinary/mixed/chord-off provenance, planned Return/Tab versus pasted whitespace, corrected suffix context, guided/unaided/hinted credit, legacy migration, and teaching despite a saved Recall preference. The AppKit harness uses disposable defaults and a focus injection; it does not show a window or send system keystrokes. Core tests cover curriculum filtering, contextual review, spaced scheduling, and finite listening. Results and the limits of the visual checks are recorded in [validation.md](validation.md).

## Follow-up implementation

GPT-6.1 Sol at Max implemented onboarding and editor transfer; XHigh implemented lesson stages, accessibility, and imports; High implemented hardware checks and ergonomic trials. The parent reviews their combined changes, with an additional independent XHigh review of learning and input boundaries.

- A first-run local field demonstrates press/release, teaches sat/hat/tan, requires an actual chord Undo recovery, and offers immediate recall or course test-out. It uses the current mappings and keyboard limits. It needs no global tap or Accessibility grant; focus loss discards pending output and rearms recovery safely. Existing installs keep their settings and skip automatic onboarding.
- New profiles opt into typing in other apps explicitly. Permission polling cannot bypass that choice. Readiness distinguishes local practice from missing permission, Secure Input, and global chord mode; the course has an explicit setup route.
- Course lessons expose See → Try → fresh Recall → Use. Demonstrations name printed keys and Start/Vowel/End roles. Assistance and errors do not earn a clean pass. Lesson-level delayed checks use aggregate epoch days, invalidate changed mappings, and require three successful later due checks spanning at least four days; same-day repetition cannot establish retention. This is a transparent scheduling rule awaiting human evaluation.
- A voluntary TextEdit scratch exercise teaches punctuation, cursor movement, chord Undo, ordinary mode, and C++ indentation/pairs where applicable. KeyChord does not inspect the editor document or score it; the saved result is explicitly self-reported.
- Practice text size is persisted in a bounded 16–30 pt range without clearing the draft. A navigable text keyboard supplements individual key accessibility elements; state and roles have textual cues, errors/completions have announcements, and Increase Contrast uses stronger solid borders. Demonstrations advance manually without animation.
- Short local checks distinguish measured related ISO wiring, derived ANSI predictions, saved scan evidence, and unchecked hardware. They capture simultaneous target keys and missing/extra evidence, support retry/cancel, and never diagnose a matrix from one incomplete attempt. Keyboard geometry and computer model are not presented as the identity of a connected device.
- Optional English trials compare current use/you routes with the two proposed shortcuts in fresh/after-word contexts and reversed order. Proposed briefs exist only in an isolated copy. Explicitly saved reports contain aggregate durations, corrections, and comfort ratings; no automatic winner or dictionary change follows. See [hardware-experiments.md](hardware-experiments.md).

## Remaining prioritized changes and validation

The audit recommendations below remain the broader acceptance targets. The statuses describe this implementation; they do not imply that unperformed human, accessibility, retention, or hardware experiments have passed.

1. **P0 — Qualify completion and speed credit.** Track accepted chord output, ordinary input/paste, assistance, corrections, and pauses per session. Separate Practiced, Recalled, and Retained; migrate old completion as legacy practice rather than inferred mastery. Main files: `TypingGuideWindow.swift`, `ChordPractice.swift`, `Storage.swift`.
   **Status:** Implemented chord provenance, practice/pass classification, and dated lesson/chord check UI; human retention outcomes remain unmeasured.
   **Accept:** with chord typing off, pasting or normally typing a matching passage earns no chord-speed record or recall/retention credit. Mixed input is classified transparently. Guided/hinted success earns practice only. Equivalent alternative chords still qualify when output and context match; breaks and correction do not inflate or unfairly penalize speed.

2. **P1 — Make beginner hints locate real keys.** Put printed keys first, meanings second; label Start, Vowel, and End in text. Use detected legends consistently and explain the two positions that produce t. Main files: `KeyLabelStyle.swift`, `ChordText.swift`, `TypingGuideWindow.swift`, `PracticeUI.swift`.
   **Status:** Implemented printed-key prominence and textual roles; fresh-profile usability study remains.
   **Accept:** a fresh profile can find S + C + J for sat directly; the C key is visibly identified as producing a. ISO Spell uses its actual printed legend. Saved advanced preferences persist; information does not depend on color.

3. **P1 — Review complete words in varied context.** Replace raw-output review candidates with valid words/phrases whose verified plan includes the target chord. Show suffix transformations as whole words; keep intentional fragment drills explicitly named and separate. Main file: `ChordPractice.swift`.
   **Status:** Implemented verified whole-word/phrase review; human variety/transfer evaluation remains.
   **Accept:** ordinary review never presents unlabeled “looke” or “neede”; meaningful contexts exercise the weak chord, use only available skills, and vary across rounds. Snippets, suffixes, and punctuation retain correct context.

4. **P1 — Split heavy lessons and limit introductory examples.** Start with two or three new mappings per episode as a hypothesis; split 10–11-item lessons and brief sets. Teach pair rules with a few known examples; move full tables to Reference. Main files: `Course.swift`, `PracticeGenerator.swift`, `TypingGuideWindow.swift`.
   **Status:** Implemented curriculum splitting and generator filtering; two-to-three-mapping sizing is still an experimental hypothesis.
   **Accept:** each episode has one objective and a short new-example check. All visible examples use taught components or explicitly introduce them. Existing progress migrates safely and generated exercises remain chord-typeable.

5. **P1 — Guide demonstration, practice, recall, and retention.** Add See it → Try it → Recall it → Use it with test-out, optional hints, and a later check. Preserve objectives while hiding answers; separate instructional examples from answer-bearing material in current intros.
   **Status:** Implemented See/Try/Recall/Use, explicit fresh test-out, hints, separate passes, and learner-facing delayed checks. Human learning and transfer evaluation remain.
   **Accept:** a persisted recall preference cannot skip teaching new material. Hints preserve place and classify assistance correctly. Recall uses unfamiliar constructible examples; retention requires a delayed unassisted check with transparent criteria.

6. **P1 — Schedule review.** Store per-skill last practice, recent unassisted successes, and review due date; use recent assistance rather than lifetime hint penalties. Offer Review due beside Continue. Main files: `ChordPractice.swift`, `Storage.swift`, `LearningUI.swift`.
   **Status:** Implemented aggregate schedules, mapping isolation, recent-assistance ranking, and Review due; experimental validation remains.
   **Accept:** delayed review becomes due independently of same-sitting repetition; successful recall adjusts priority and timing. Old records decode safely, mapping changes remain isolated, and no passages or raw keystroke logs are persisted. Validate scheduling experimentally.

7. **P1 — Compact the active practice layout.** Keep current target, typed result, required keys, readiness, and feedback together. Collapse understood introductions, use nearby passage context, move reference to a side pane/disclosure, and hide historical detail behind disclosure. Main files: `TypingGuideWindow.swift`, `PracticeUI.swift`, `LearningUI.swift`.
   **Status:** Implemented compact layout, disclosures, text sizing, a navigable text keyboard, accessibility announcements, and Increase Contrast handling. Native preview results are in validation.md; human VoiceOver operation remains to be evaluated.
   **Accept:** those core elements remain visible together at the supported laptop-window size with long imports. Check narrow windows, keyboard navigation, VoiceOver, text scaling, Increase Contrast, and Reduced Motion. History and session results have distinct labels.

8. **P1 — Make readiness and recovery explicit.** Add Start chord practice near the target, visible permission/Secure Input/mode state, a press-and-release exercise, and a real undo correction task. Diagnose missing/extra keys only when captured evidence supports it; distinguish hardware predictions from observed failures.
   **Status:** Implemented readiness, router-backed Start/Pause, local press/release onboarding, dedicated Undo recovery, and short captured-key checks. Physical reliability remains unmeasured; incomplete captures are not labeled hardware diagnoses.
   **Accept:** chord-off input cannot look ready for scored practice. The learner can activate the required mode and recover from a mistake. Alternatives are verified for output/context and available hardware constraints; one failed attempt never proves a dropped key.

9. **P2 — Improve session discovery and optional tracks.** Lead Practice with Continue/Review due, keep custom text discoverable, make C++ optional with separate progress, and allow imported-language override. Unify Learn, Practice, Reference, and Settings; add a short original-writing transfer task in a real editor.
   **Status:** Implemented separate English/C++ progress, personal practice discovery, visible import-language override, staged lesson navigation, and optional real-editor tasks. Editor completion is self-reported; measured transfer and human evaluation of editor auto-pairs remain.
   **Accept:** English completion does not require C++; track switching preserves progress. Import detection can be overridden. Verify transfer with punctuation, cursor movement, undo, indentation, and editor auto-pairs.

10. **P2 — Adapt listening to learned skills.** Add My learned chords/All vocabulary, finite sessions, replay/pacing controls, a text-recall alternative, and separate word reveal from chord reveal. Main files: `ListeningPractice.swift`, `PracticeSpeaker.swift`, `TypingGuideWindow.swift`.
   **Status:** Implemented learned/all vocabulary, ten-word sessions, replay, explicit pacing, and separate word/chord reveals; human pacing/audio accessibility validation remains.
    **Accept:** learned-only prompts require no untaught skill and no normal-input fallback. Completion waits for the chosen pace, reveal assistance is tracked, and users can finish a session without audio.

11. **P2 — Expose hardware confidence and defer advanced setup.** Show tested here / predicted from related model / not checked; offer a short relevant-chord check and verified alternatives. Keep matrix scanning advanced. Add local composition for a first-chord sandbox before requesting global Accessibility permission.
   **Status:** Implemented confidence UI, short relevant-chord checks and capital alternatives, and a local first-chord engine before global permission. Human hardware testing remains.
    **Accept:** measured ISO, derived ANSI, and unknown hardware are distinguishable. Capital fingerspelling alternatives avoid the four modeled blocked defaults. The short check produces useful feedback; local onboarding works without global interception and requests permission at editor transfer.

## Optional experiments after the learning fixes

- Assess human execution time, corrections, comfort, transitions, and retention before changing mappings or planner preferences. Version any adopted additions and preserve familiar routes.
- An opt-in isolated English trial now compares Spell + U + S → use and Spell + Y + O → you with their current routes. The first chord still means using in C++. Neither candidate has been human-tested; neither is installed automatically.
- The repository’s top100 is a test list, not independently validated frequency coverage: 99/100 words use one chord under either bundled model. These counts establish neither human speed nor a global optimum. Keep physical-key load, hand balance, hardware confidence, and relearning cost in the evaluation.
