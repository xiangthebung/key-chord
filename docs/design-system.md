# Shared design and first-chord flow

`Resources/design-system.json` defines the light/dark palette, keyboard role colors, spacing, sizes, typography, and section/stage labels. Exercise content is 720 points/pixels wide and its keyboard guide is 680. Unrelated keys use neutral surfaces; highlighted keys use the shared blue accent. Role colors remain available for the full reference.

`Resources/presentation.json` owns first-chord presentation and progression: See → Try → Undo → Recall, guided words, recall words, the mistake/Undo/repair sequence, hint visibility, required completion events, titles, instructions, placeholders and primary actions. Its demonstration waits for the last key release before displaying output. Edit these source files, then generate both platforms:

```sh
python3 scripts/export-design.py
python3 scripts/export-design.py --check
```

The default website destination is the sibling `macbook-keyboard-matrix/docs` directory. Use `--web-dir /path/to/website/docs` for another checkout.

Generated outputs are:

- Native `Sources/KeyChordCore/DesignSystem.swift` and `Presentation.swift`.
- Website `design-tokens.css`, `design.js`, `design.json`, `keychord/presentation.js`, and `keychord/presentation.json`.

The matrix and browser app load the CSS; the browser app imports `DESIGN` for labels and the generated presentation module for views and flow. Native `PracticeUI` adapts the shared values to macOS colors and controls, including increased-contrast borders. Generated files carry a header and must not be edited independently.

Swift `KeyChordPresentation.firstChord(...)` and browser `firstChordPresentation(...)` produce the same view contract. `nextFirstChordState(...)` in both platforms reads the same finite transition chain. The browser introduction consumes that transition chain. Native learning uses a single local Practice window showing the activity chosen from the Practice submenu: Words, Lessons, or Voice Practice. Practice fills the available width, with a permanent keyboard below its typing box. The Hint action and shortcut reveal one word; Lessons automatically introduce each new combination on first use. There are no mode tabs. Lessons reuse the course content and persisted lesson identifiers. Voice uses verified chord plans, spoken feedback, and automatic prompt advancement. Core stage names `tryIt` and `recover` still adapt to canonical presentation IDs `try` and `undo` for the browser contract. Native migration preserves the user's global typing choice.

The browser presentation reducer requires a released physical word chord or an actual Undo chord for completion. Native Practice scores real local text edits through the shared chord engine and distinguishes guided, chord, ordinary, and mixed input.

Check source/generated parity and view behavior with:

```sh
python3 scripts/export-design.py --web-dir /path/to/website/docs --check
scripts/test.sh --filter PresentationTests
cd /path/to/website/docs/keychord
node --test tests/presentation.mjs
```

The exporter validates the finite flow, stage IDs, word order, recovery sequence and release-before-output demonstration. Native and browser tests compare every state's view and successor against the declarative source, including both hint settings and every demonstration phase.

The native course, dictionaries, keyboard geometry, and engine fixtures are exported separately by the website's `docs/keychord/scripts/export-native.swift`. Those are shared data; the first-chord transition reducer is generated shared logic. Chord translation still runs in native Swift and a browser JavaScript port checked against native fixtures. Input capture, focus leases, speech, ordinary editing and storage remain platform adapters.

The project currently has no Swift/Wasm build or browser interop layer. Reusing the Swift engine binary in-browser would require that build plus a JavaScript bridge for key events, text/cursor offsets, translation results and context lifetime. That is a separate runtime change; this contract deliberately shares the UI/content/flow without claiming the two engine implementations are already one runtime.
