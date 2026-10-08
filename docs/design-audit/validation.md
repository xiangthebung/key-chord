**Follow-up validation — October 7, 2026**

Small wording, label, and visual fixes were handled directly. GPT-6.1 Sol implemented the larger changes at High, XHigh, and Max: curriculum and review; lesson stages, accessibility, and imports; local onboarding and editor transfer; hardware checks and ergonomic trials. The parent reviewed the combined changes, including an independent XHigh review of learning and input boundaries. The [implementation plan](implementation-plan.md) distinguishes implemented behavior from remaining human validation.

**Automated checks**

- `scripts/test.sh`: 214 tests across 31 suites passed. The reported known issue is the existing intentional negative mistake-recovery check: omitting context restoration is expected to lose spacing. It is not a new failing test. The added checks cover local composition, delayed lesson scheduling, hardware evidence, and isolated ergonomic trials.
- `scripts/test-practice-ui.sh`: 799 passages and 4,284 chords passed using the actual AppKit practice controller under unrestricted planning and both bundled keyboard models. The harness checks paste/ordinary/mixed/chord-off exclusion, guided and unaided credit, assistance, structural Return/Tab, suffix corrections, and legacy progress migration. New assertions cover See/Try/Recall/Use, fresh Recall answer hiding before any key event, visible help after restart, delayed evidence, import-language preservation, text sizing, and keyboard accessibility elements. It uses disposable defaults and sends no system keystrokes.
- `scripts/test-onboarding-ui.sh`: passed using actual NSTextView editing and local event values. It checks full release before output, chord Undo, ordinary Delete/paste/selection/cursor edits, focus loss and readiness, recovery rearming, mode-switch recovery, Caps Lock, unavailable mappings, local/global ownership collision, legacy launch, and persistence limited to journey choices. It never displays a window or posts system keys.
- Debug builds passed during both native check scripts. `swift build -c release --product KeyChord` passed after the final focus, wording, and narrow-window fixes.
- `git diff --check`: passed.
- The separate reviewed app's code signature verified with `codesign --verify --deep --strict`.

The curriculum checks verify that all 34 original lesson IDs retain their introduced skills after migration to 52 lessons. Each current lesson has at most four explicit skill entries; categories such as spelling, digits, and pair rules can cover more physical mappings. Generated exercises and learned-only listening are checked against taught skills and the keyboard models.

**Native visual and interaction checks**

An isolated preview instantiated the real practice, onboarding, editor bridge, keyboard check, and ergonomic trial controllers with bundled sample data, disposable defaults, and a separate app identity. It did not launch the global event router or request Accessibility permission. Preview readiness callbacks are simulated; this is interaction and presentation validation, not human chord performance evidence.

- Requested laptop content size 1024 × 768 and narrow content size 390 × 700; inspected light and dark appearances. The compact Try/Recall cards, target, chord hint, input, readiness, and short passage fit at laptop size with optional detail collapsed. Narrow windows wrap content and allow vertical scrolling; readiness now wraps instead of truncating its right Option instruction. Expanded keyboard/reference content can still require scrolling.
- Verified that printed keys are prominent, with Start/Vowel/End roles in text; Recall retains its objective while hiding chord answers.
- Verified onboarding's held/partial-release/all-release demonstration and editable local field. Pasting `sat` keeps the task in Try and explains that an ordinary edit cannot finish the chord task. The corrected readiness label immediately says local chords are on when the field acquires focus.
- Switched a C++ import to English and retained its passage and draft. Set text size to 30 pt without clearing the draft. Opened Keys as text and used an arrow key to navigate table rows containing physical keys, meanings, roles, and target/released state; both Shift keys are represented.
- Skipped all three short keyboard targets: the result showed zero observed attempts. Started and cancelled the optional ergonomic trial: all four route summaries remained unmeasured, with zero trials and no inferred preferred route.
- Inspected the editor bridge with permission missing: Open scratch exercise and I tried these tasks stayed disabled. The instructions and stored result explicitly identify editor completion as self-report.
- Pasting the full displayed passage produced “Text matched,” zero chord WPM credit, and an explanation of how to earn practice credit.
- Preview Start/Pause changed the displayed readiness state correctly. This checks the UI callback and presentation; real permission, Secure Input, and event-tap behavior were inspected in source rather than exercised by the preview.
- Personal review and custom text are near the top of Practice. English progress displays 45 lessons; the seven C++ lessons are marked optional separately.
- A new profile's learned-only listening displays a useful empty state. All vocabulary starts a ten-word session; Show word reveals text while keeping the chord answer hidden.
- Primary buttons now use the native accent color, resolving the observed white-text-on-light-teal issue.

Review and native preview exposed and resolved a TextKit initialization crash, an asynchronous Recall answer leak, a help/restart assistance reset, a rejected mode switch that could trap local input in C++, and an Undo exercise stranded by focus loss. Native regressions cover those input and learning boundaries. A final read-only review found no new actionable issue in the readiness callback or editor key-label changes.

Human VoiceOver operation, system Increase Contrast and Reduced Motion settings, physical chord reliability, comfort, delayed learning outcomes, and actual transfer to external editors remain untested. Text sizing and text-table navigation were exercised; announcements and contrast handling were inspected in source and native assertions. The global tap, real permission prompts, and Secure Input were inspected in source rather than exercised by the preview. These are explicit remaining validation tasks, not implied achievements.

**Combination measurements**

[chord-measurements.json](chord-measurements.json) preserves the original audit baseline. [chord-measurements-current.json](chord-measurements-current.json) records the revised curriculum. The measurement script reproduces the current data.

- The mapping identities are unchanged. The repository's 100-word test list still has 100 one-chord words with no blocking assumed and 99 with either bundled keyboard model; no normal-typing fallback is needed.
- The revised 52 course passages require 759 chords with no blocking assumed and 764 with either bundled model; no normal-typing fallback is needed. The larger total reflects changed course content, not a speed regression measurement.
- Experimental shortcuts for “use” and “you” are available only in the optional local trial. They are not installed in the normal dictionaries. Model-predicted compatibility does not establish comfortable execution or better learning; no human trial results were recorded.

**Reviewed build**

The release executable is packaged in the existing `build/KeyChord.app`. The website download is `downloads/KeyChord.zip`, containing `KeyChord.app`. The build updates that bundle in place and preserves existing permissions. Development history is kept in Git; dated and suffix build copies have been removed.
