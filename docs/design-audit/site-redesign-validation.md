# Shared app and website redesign validation

Both clients now use a compact centered exercise, a separate lesson/practice chooser, primary Lessons/Practice navigation and a Tools menu. The keyboard follows the typing area and uses neutral inactive keys. A physical-key-to-sound mapping pairs each group explicitly. Course counts, review rules, references, history and advanced checks are outside the immediate exercise.

`Resources/design-system.json` owns visual tokens. `Resources/presentation.json` owns the first-chord transition chain, target words, Undo recovery, hint visibility, required completion events and demonstration phases. Generated Swift and JavaScript reducers read the same contract. Native and browser input owners continue to verify actual physical capture before advancing; demonstrations do not earn physical credit. The browser chord engine is still a fixture-tested JavaScript port; this change does not introduce Swift/Wasm.

Validation completed:

- Full native Core suite: 219 tests in 32 suites passed, with one pre-existing known issue in the mistake-recovery/book sample test.
- AppKit practice harness: 799 passages and 4,284 chords across generic, ISO and ANSI keyboards. Target-before-input, keyboard-last and single-primary-action checks passed. Permission blocking exposes one action even after an exercise refresh.
- Native onboarding harness: shared demonstration actions, no output before final release, read-only demonstration, editable local Try input, physical release, actual Undo, ordinary correction, focus, mode, Caps Lock and privacy checks passed.
- Actual website repository: 90 Node tests passed, including generated presentation/source parity and the finite guided/Undo/recall chain.
- Browser interaction: See demonstration, physical sat/hat/tan, actual Undo and correction, all three hidden-guide recall words, lesson navigation, topic practice and imported draft input worked. No browser console errors were reported.
- Browser visual check: desktop light/dark modes, keyboard below the input, and a narrow effective viewport of 312 px. No document overflow; the physical keyboard scrolls within its own region on narrow screens.
- Deterministic exporter `--check`, JavaScript syntax, and whitespace checks passed.

The release updates `build/KeyChord.app` in place under its existing bundle identifier. The dated/suffix/preview development bundles were removed. Existing user settings, data backups and the older installed input-method bundle were preserved. The build script now renews Accessibility grants for ad-hoc builds and opens the app; certificate-signed builds preserve grants by default. The website archive is `downloads/KeyChord.zip` containing `KeyChord.app`.

Native live screen capture was unavailable because the computer-use service timed out while resolving app windows; native visual layout is covered by AppKit frame/order checks rather than a live screenshot. The browser screenshot is `site-redesign-2026-10-07.jpg`.

Changes are committed locally in the native and website repositories. The public GitHub Pages site has not been published by this task.
