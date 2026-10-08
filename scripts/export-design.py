#!/usr/bin/env python3
"""Generate shared native/browser design and first-chord presentation contracts."""

import argparse
import json
import math
from pathlib import Path
import re
import sys


ROOT = Path(__file__).resolve().parent.parent
DEFAULT_WEB_DIR = ROOT.parent / "macbook-keyboard-matrix" / "docs"


def load_spec():
    spec = json.loads((ROOT / "Resources" / "design-system.json").read_text())
    if spec.get("schemaVersion") != 1:
        raise ValueError("Unsupported design schemaVersion")
    for group in ("palette", "rolePalette"):
        if set(spec[group]) != {"light", "dark"}:
            raise ValueError(f"{group} needs light and dark themes")
        if set(spec[group]["light"]) != set(spec[group]["dark"]):
            raise ValueError(f"{group} theme tokens must match")
        for palette in spec[group].values():
            for name, color in palette.items():
                if not re.fullmatch(r"[a-z][a-z-]*", name):
                    raise ValueError(f"Invalid color token: {name}")
                if not isinstance(color, str) or not re.fullmatch(r"#[0-9a-f]{3}(?:[0-9a-f]{3})?", color):
                    raise ValueError(f"Invalid color: {name}")
    expected_colors = {"fg", "muted", "bg", "line", "key", "guide", "unmapped", "unmapped-text", "wire", "on", "on-edge",
                       "on-hover", "warm", "warm-soft", "bad", "bad-text", "bad-soft", "bad-fill", "bad-edge"}
    expected_roles = {"onset", "vowel", "coda", "spell", "special", "number", "space"}
    if set(spec["palette"]["light"]) != expected_colors or set(spec["rolePalette"]["light"]) != expected_roles:
        raise ValueError("Palette tokens must match the shared interface and keyboard roles")
    for group in ("metrics", "typography"):
        for name, value in spec[group].items():
            if not re.fullmatch(r"[a-z][a-zA-Z]*", name):
                raise ValueError(f"Invalid Swift identifier: {name}")
            if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or value <= 0:
                raise ValueError(f"Invalid numeric token: {name}")
    expected_labels = {
        "sections": {"learn", "practice", "listen", "editor", "reference", "hardware", "settings"},
        "stages": {"see", "try", "recall", "use"},
    }
    for group, expected in expected_labels.items():
        if set(spec["labels"][group]) != expected:
            raise ValueError(f"{group} label IDs must match the shared navigation")
        if any(not isinstance(value, str) or not value or any(ord(c) < 32 for c in value)
               for value in spec["labels"][group].values()):
            raise ValueError(f"Invalid {group} label")
    return spec


def load_presentation():
    spec = json.loads((ROOT / "Resources" / "presentation.json").read_text())
    if spec.get("schemaVersion") != 1:
        raise ValueError("Unsupported presentation schemaVersion")
    flow = spec["firstChord"]
    if flow["stageOrder"] != ["see", "try", "undo", "recall"]:
        raise ValueError("First-chord stages must be See, Try, Undo, Recall")
    if set(flow["stages"]) != set(flow["stageOrder"] + ["finished"]):
        raise ValueError("First-chord stage definitions must match the flow")
    ordered_stages = flow["stageOrder"] + ["finished"]
    for index, stage in enumerate(ordered_stages):
        content = flow["stages"][stage]
        expected_next = ordered_stages[index + 1] if index + 1 < len(ordered_stages) else None
        if content["nextStageID"] != expected_next:
            raise ValueError("Presentation next-stage IDs must match the ordered flow")
        for flag in ("hintsVisible", "physicalReleaseRequired"):
            if not isinstance(content[flag], bool):
                raise ValueError(f"{flag} must be a boolean")
    if flow["recoverySequence"] != ["mistake", "undo", "repair"]:
        raise ValueError("Recovery must make a mistake, undo it, then repair it")
    if set(flow["recovery"]) != set(flow["recoverySequence"]):
        raise ValueError("Recovery definitions must match the sequence")
    states = flow["states"]
    by_id = {state["id"]: state for state in states}
    if len(by_id) != len(states):
        raise ValueError("First-chord state IDs must be unique")
    seen = set()
    current = "see"
    while current is not None:
        if current in seen or current not in by_id:
            raise ValueError("First-chord flow must be a finite complete chain")
        seen.add(current)
        state = by_id[current]
        if state["stage"] not in flow["stages"] or state["recovery"] not in flow["recovery"]:
            raise ValueError("Unknown first-chord stage or recovery state")
        if isinstance(state["wordIndex"], bool) or not isinstance(state["wordIndex"], int) or state["wordIndex"] < 0:
            raise ValueError("First-chord word indices must be nonnegative integers")
        if state["completion"] not in {"start", "physicalWord", "physicalUndo", "none"}:
            raise ValueError("Unknown completion event")
        if state["target"] is not None and (not isinstance(state["target"], str) or not state["target"]):
            raise ValueError("First-chord targets must be nonempty words or null")
        if state["completion"] == "physicalWord" and not state["target"]:
            raise ValueError("Physical-word completion needs a target")
        if state["completion"] == "physicalUndo" and state["target"] is not None:
            raise ValueError("Physical Undo must end with an empty field")
        if state["completion"].startswith("physical") and not flow["stages"][state["stage"]]["physicalReleaseRequired"]:
            raise ValueError("Physical completion must require a released chord")
        current = state["next"]
    if seen != set(by_id) or states[-1]["stage"] != "finished":
        raise ValueError("Every first-chord state must be reachable and finish")
    for stage, words in (("try", flow["guidedWords"]), ("recall", flow["recallWords"])):
        actual = [state["target"] for state in states if state["stage"] == stage]
        if actual != words or [state["wordIndex"] for state in states if state["stage"] == stage] != list(range(len(words))):
            raise ValueError(f"{stage} words must match their ordered flow states")
    demo = flow["demonstration"]
    if [phase["id"] for phase in demo] != ["ready", "held", "partial", "released"]:
        raise ValueError("Demonstration must show a complete press/release cycle")
    if any(phase["output"] is not None for phase in demo[:-1]) or demo[-1]["output"] != by_id["see"]["target"]:
        raise ValueError("Demonstration output may appear only after the final release")
    if [phase["held"] for phase in demo] != ["none", "all", "last", "none"]:
        raise ValueError("Demonstration held-key states must match the release sequence")
    if set(spec["lessons"]) != {"see", "try", "recall", "use"}:
        raise ValueError("Lesson presentation must match LearningStage")
    return spec


def swift_string(value):
    return json.dumps(value, ensure_ascii=False)


def swift_dictionary(name, values, indent="        "):
    rows = [f'{indent}    {swift_string(key)}: {swift_string(value)},' for key, value in sorted(values.items())]
    return f"{indent}public static let {name}: [String: String] = [\n" + "\n".join(rows) + f"\n{indent}]"


def swift_source(spec):
    parts = ["// Generated by scripts/export-design.py from Resources/design-system.json. Do not edit.\n",
             "/// Shared visual values and names. Platform adapters own colors, controls, and input.\n",
             "public enum DesignSystem {\n",
             f'    public static let schemaVersion = {spec["schemaVersion"]}\n']
    for group, enum_name in (("metrics", "Metrics"), ("typography", "Typography")):
        rows = [f"        public static let {key}: Double = {float(value):g}" + (".0" if float(value).is_integer() else "")
                for key, value in sorted(spec[group].items())]
        parts.append(f"\n    public enum {enum_name} {{\n" + "\n".join(rows) + "\n    }\n")
    for group, enum_name in (("palette", "Palette"), ("rolePalette", "RolePalette")):
        parts.append(f"\n    public enum {enum_name} {{\n" +
                     "\n\n".join(swift_dictionary(theme, spec[group][theme]) for theme in ("light", "dark")) + "\n    }\n")
    parts.append("\n    public enum Labels {\n" +
                 "\n\n".join(swift_dictionary(group, spec["labels"][group]) for group in ("sections", "stages")) + "\n    }\n}\n")
    return "".join(parts)


def kebab(name):
    return re.sub(r"[A-Z]", lambda match: "-" + match[0].lower(), name)


def css_palette(spec, theme, indent="  "):
    values = dict(spec["palette"][theme])
    values.update({"role-" + key: value for key, value in spec["rolePalette"][theme].items()})
    return "\n".join(f"{indent}--{key}: {value};" for key, value in sorted(values.items()))


def css_source(spec):
    metrics = [f"  --{kebab(key)}: {value:g}px;" for key, value in sorted(spec["metrics"].items())]
    fonts = [f"  --font-{kebab(key)}: {value:g}px;" for key, value in sorted(spec["typography"].items())]
    return ("/* Generated by scripts/export-design.py from Resources/design-system.json. Do not edit. */\n"
            ":root {\n  color-scheme: light dark;\n" + css_palette(spec, "light") + "\n" +
            "\n".join(metrics + fonts) + "\n}\n\n"
            '@media (prefers-color-scheme: dark) {\n  :root:not([data-theme="light"]) {\n' +
            css_palette(spec, "dark", "    ") + "\n  }\n}\n\n"
            ':root[data-theme="dark"] {\n  color-scheme: dark;\n' + css_palette(spec, "dark") + "\n}\n\n"
            ':root[data-theme="light"] { color-scheme: light; }\n')


SWIFT_STAGES = {"see": "see", "try": "tryIt", "undo": "recover", "recall": "recall", "finished": "finished"}
SWIFT_RECOVERY = {"mistake": "makeMistake", "undo": "undoMistake", "repair": "repair"}


def optional_string(value):
    return "nil" if value is None else swift_string(value)


def swift_title(template):
    return " + wordForTitle + ".join(swift_string(part) for part in template.split("{word}"))


def presentation_swift_source(spec):
    flow = spec["firstChord"]
    states = []
    for state in flow["states"]:
        states.append('        FirstChordFlowState(id: ' + swift_string(state["id"]) +
                      ', stage: .' + SWIFT_STAGES[state["stage"]] + ', wordIndex: ' + str(state["wordIndex"]) +
                      ', recovery: .' + SWIFT_RECOVERY[state["recovery"]] + ', target: ' + optional_string(state["target"]) +
                      ', completion: ' + swift_string(state["completion"]) + ', nextID: ' + optional_string(state["next"]) + '),')
    cases = []
    for state in flow["states"]:
        content = dict(flow["stages"][state["stage"]])
        if state["stage"] == "undo":
            content.update(flow["recovery"][state["recovery"]])
        instruction = "demo.instruction" if state["stage"] == "see" else swift_string(content["instruction"])
        action = "demo.primaryAction" if state["stage"] == "see" else swift_string(content["primaryAction"])
        action_id = '(demo.output == nil ? "demonstrate" : "start")' if state["stage"] == "see" else swift_string(content["primaryActionID"])
        cases.append(f'''        case {swift_string(state["id"])}:
            return FirstChordPresentation(stageID: {swift_string(state["stage"])}, label: {swift_string(content["label"])},
                title: {swift_title(content["title"])}, instruction: {instruction}, target: target,
                primaryAction: {action}, primaryActionID: {action_id}, placeholder: {swift_string(content.get("placeholder", flow["placeholder"]))},
                hintsVisible: {str(content["hintsVisible"]).lower()} || hintRevealed,
                physicalReleaseRequired: {str(content["physicalReleaseRequired"]).lower()}, nextStageID: {optional_string(content["nextStageID"])})''')
    demos = ['        FirstChordDemoPresentation(id: ' + swift_string(phase["id"]) +
             ', instruction: ' + swift_string(phase["instruction"]) + ', primaryAction: ' + swift_string(phase["primaryAction"]) +
             ', held: ' + swift_string(phase["held"]) + ', output: ' + optional_string(phase["output"]) + '),'
             for phase in flow["demonstration"]]
    lessons = [f'''        case .{"tryIt" if stage == "try" else stage}:
            return LessonPresentation(title: {swift_string(content["title"])}, instruction: {swift_string(content["instruction"])}, primaryAction: {swift_string(content["primaryAction"])})'''
               for stage, content in spec["lessons"].items()]
    arrays = "\n".join(f'    public static let {name}: [String] = [' + ', '.join(swift_string(value) for value in flow[key]) + ']'
                       for name, key in (("guidedWords", "guidedWords"), ("recallWords", "recallWords"),
                                         ("stageOrder", "stageOrder"), ("recoverySequence", "recoverySequence")))
    return '''// Generated by scripts/export-design.py from Resources/presentation.json. Do not edit.
// The contract owns words, demonstration phases, presentation and progression. Input adapters
// still verify actual physical chord releases before accepting a completion.

public struct FirstChordFlowState: Equatable, Sendable {
    public let id: String
    public let stage: FirstChordStage
    public let wordIndex: Int
    public let recovery: FirstChordJourney.Recovery
    public let target: String?
    public let completion: String
    public let nextID: String?
}

public struct FirstChordPresentation: Equatable, Sendable {
    public let stageID: String
    public let label: String
    public let title: String
    public let instruction: String
    public let target: String?
    public let primaryAction: String
    public let primaryActionID: String
    public let placeholder: String
    public let hintsVisible: Bool
    public let physicalReleaseRequired: Bool
    public let nextStageID: String?
}

public struct FirstChordDemoPresentation: Equatable, Sendable {
    public let id: String
    public let instruction: String
    public let primaryAction: String
    /// none, all, or last; drawing adapters resolve these against the current chord recipe.
    public let held: String
    public let output: String?
}

public struct LessonPresentation: Equatable, Sendable {
    public let title: String
    public let instruction: String
    public let primaryAction: String
}

public enum KeyChordPresentation {
''' + arrays + '''

    private static let states: [FirstChordFlowState] = [
''' + "\n".join(states) + '''
    ]
    private static let demonstration: [FirstChordDemoPresentation] = [
''' + "\n".join(demos) + '''
    ]

    public static var firstChordDemonstrationCount: Int { demonstration.count }
    public static func firstChordDemonstration(step: Int) -> FirstChordDemoPresentation {
        demonstration[max(0, min(step, demonstration.count - 1))]
    }

    public static func firstChordState(stage: FirstChordStage, wordIndex: Int = 0,
                                      recovery: FirstChordJourney.Recovery = .makeMistake) -> FirstChordFlowState {
        let count = stage == .tryIt ? guidedWords.count : stage == .recall ? recallWords.count : 1
        let index = max(0, min(wordIndex, count - 1))
        let recovery = stage == .recover ? recovery : .makeMistake
        return states.first { $0.stage == stage && $0.wordIndex == index && $0.recovery == recovery }!
    }

    /// Call only after the completion named by firstChordState has been verified by the input owner.
    public static func nextFirstChordState(stage: FirstChordStage, wordIndex: Int = 0,
                                          recovery: FirstChordJourney.Recovery = .makeMistake) -> FirstChordFlowState? {
        let state = firstChordState(stage: stage, wordIndex: wordIndex, recovery: recovery)
        guard let next = state.nextID else { return nil }
        return states.first { $0.id == next }
    }

    public static func firstChord(stage: FirstChordStage, word: String? = nil, wordIndex: Int = 0,
                                  recovery: FirstChordJourney.Recovery = .makeMistake, hintRevealed: Bool = false,
                                  demonstrationIndex: Int = 0) -> FirstChordPresentation {
        let state = firstChordState(stage: stage, wordIndex: wordIndex, recovery: recovery)
        let target = state.target == nil ? nil : (word ?? state.target)
        let wordForTitle = target ?? ""
        let demo = firstChordDemonstration(step: demonstrationIndex)
        switch state.id {
''' + "\n".join(cases) + '''
        default: preconditionFailure("Unknown generated first-chord state")
        }
    }

    public static func lesson(stage: LearningStage) -> LessonPresentation {
        switch stage {
''' + "\n".join(lessons) + '''
        }
    }
}
'''


def presentation_js_source(spec):
    return ('// Generated by scripts/export-design.py from Resources/presentation.json. Do not edit.\n'
            'function freeze(value) { if (value && typeof value === "object") { Object.values(value).forEach(freeze); Object.freeze(value); } return value; }\n'
            'export const PRESENTATION = freeze(' + json.dumps(spec, ensure_ascii=False, indent=2) + ');\n' + '''
export const FIRST_CHORD = PRESENTATION.firstChord;
const aliases = {tryIt: 'try', recover: 'undo'};
const recoveries = {makeMistake: 'mistake', undoMistake: 'undo'};
function stateFor({stage, wordIndex = 0, recovery = 'mistake'}) {
  stage = aliases[stage] ?? stage;
  if (!Object.hasOwn(FIRST_CHORD.stages, stage)) throw new TypeError(`Unknown first-chord stage: ${stage}`);
  const count = stage === 'try' ? FIRST_CHORD.guidedWords.length : stage === 'recall' ? FIRST_CHORD.recallWords.length : 1;
  wordIndex = Math.max(0, Math.min(Number.isFinite(wordIndex) ? Math.trunc(wordIndex) : 0, count - 1));
  recovery = stage === 'undo' ? recoveries[recovery] ?? recovery : 'mistake';
  const state = FIRST_CHORD.states.find(s => s.stage === stage && s.wordIndex === wordIndex && s.recovery === recovery);
  if (!state) throw new TypeError(`Unknown first-chord recovery: ${recovery}`);
  return state;
}
export function firstChordState(state) { return {...stateFor(state)}; }
// Input owners verify the current state's completion event before calling this reducer.
export function nextFirstChordState(state) {
  const next = stateFor(state).next;
  return next === null ? null : {...FIRST_CHORD.states.find(s => s.id === next)};
}
export function demoPresentation(step = 0) {
  const index = Math.max(0, Math.min(Number.isFinite(step) ? Math.trunc(step) : 0, FIRST_CHORD.demonstration.length - 1));
  return {...FIRST_CHORD.demonstration[index]};
}
export function firstChordPresentation(stage, {wordIndex = 0, recovery = 'mistake', hintRevealed = false, word = null, demonstrationIndex = 0} = {}) {
  const state = stateFor({stage, wordIndex, recovery});
  const base = FIRST_CHORD.stages[state.stage];
  const content = state.stage === 'undo' ? {...base, ...FIRST_CHORD.recovery[state.recovery]} : base;
  const target = state.target === null ? null : word ?? state.target;
  const demo = demoPresentation(demonstrationIndex);
  return {stageID: state.stage, label: content.label, title: content.title.replaceAll('{word}', target ?? ''),
    instruction: state.stage === 'see' ? demo.instruction : content.instruction, target,
    primaryAction: state.stage === 'see' ? demo.primaryAction : content.primaryAction,
    primaryActionID: state.stage === 'see' ? demo.output === null ? 'demonstrate' : 'start' : content.primaryActionID,
    placeholder: content.placeholder ?? FIRST_CHORD.placeholder, hintsVisible: content.hintsVisible || hintRevealed,
    physicalReleaseRequired: content.physicalReleaseRequired, nextStageID: content.nextStageID};
}
export function lessonPresentation(stage) {
  stage = aliases[stage] ?? stage;
  if (!Object.hasOwn(PRESENTATION.lessons, stage)) throw new TypeError(`Unknown lesson stage: ${stage}`);
  return {...PRESENTATION.lessons[stage]};
}
''')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--web-dir", type=Path, default=DEFAULT_WEB_DIR,
                        help="Website docs directory (default: sibling macbook-keyboard-matrix/docs)")
    parser.add_argument("--check", action="store_true", help="Check generated outputs without changing files")
    args = parser.parse_args()
    spec = load_spec()
    presentation = load_presentation()
    outputs = {
        ROOT / "Sources" / "KeyChordCore" / "DesignSystem.swift": swift_source(spec),
        ROOT / "Sources" / "KeyChordCore" / "Presentation.swift": presentation_swift_source(presentation),
        args.web_dir / "design-tokens.css": css_source(spec),
        args.web_dir / "design.json": json.dumps(spec, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        args.web_dir / "design.js": ("// Generated by scripts/export-design.py from Resources/design-system.json. Do not edit.\n"
                                    "export const DESIGN = " + json.dumps(spec, ensure_ascii=False, indent=2, sort_keys=True) + ";\n"),
        args.web_dir / "keychord" / "presentation.js": presentation_js_source(presentation),
        args.web_dir / "keychord" / "presentation.json": json.dumps(presentation, ensure_ascii=False, indent=2) + "\n",
    }
    stale = []
    for path, content in outputs.items():
        if args.check:
            if not path.exists() or path.read_text() != content:
                stale.append(path)
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content)
    if stale:
        for path in stale:
            print(f"Stale generated file: {path}", file=sys.stderr)
        return 1
    print("Design and presentation outputs match their sources." if args.check else "Generated native and browser design and presentation outputs.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (KeyError, TypeError, ValueError) as error:
        print(f"Design specification error: {error}", file=sys.stderr)
        sys.exit(1)
