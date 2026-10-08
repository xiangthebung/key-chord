"""Exercise packaging and permission renewal without changing real macOS grants.

Run with: python3 Tests/BuildAppChecks/test_build_app.py
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[2]
MOCK_TOOL = """#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
name = Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ['BUILD_CHECK_LOG'], 'a') as log:
    log.write(json.dumps([name, *args]) + '\\n')
failure = os.environ.get('BUILD_CHECK_FAIL')
if failure == name or (failure == 'verify' and name == 'codesign' and '--verify' in args):
    print('simulated ' + failure + ' failure', file=sys.stderr)
    sys.exit(1)
if name == 'swift' and '--show-bin-path' in args:
    print(os.environ['BUILD_CHECK_BIN'])
elif name == 'pgrep':
    sys.exit(0 if Path(os.environ['BUILD_CHECK_RUNNING']).exists() else 1)
elif name == 'pkill' and os.environ.get('BUILD_CHECK_STUCK') != '1':
    Path(os.environ['BUILD_CHECK_RUNNING']).unlink()
"""


class BuildAppChecks(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="keychord-build-checks-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve() / "checkout with spaces"
        (self.root / "scripts").mkdir(parents=True)
        shutil.copy2(REPO / "build-app.sh", self.root / "build-app.sh")
        shutil.copy2(REPO / "scripts/build-app.sh", self.root / "scripts/build-app.sh")
        resources = self.root / "Resources"
        (resources / "WordLists").mkdir(parents=True)
        shutil.copy2(REPO / "Resources/Info.plist", resources / "Info.plist")
        for name in ("README.md", "COPYING"):
            shutil.copy2(REPO / "Resources/WordLists" / name, resources / "WordLists" / name)
        self.bin = self.root / "compiled"
        self.bin.mkdir()
        (self.bin / "KeyChord").write_text("new executable")
        self.mock_dir = self.root / "mock-tools"
        self.mock_dir.mkdir()
        for name in ("swift", "pgrep", "pkill", "sleep", "codesign", "tccutil", "open"):
            command = self.mock_dir / name
            command.write_text(MOCK_TOOL)
            command.chmod(0o755)
        self.log = self.root / "calls.jsonl"
        self.running = self.root / "running"
        self.env = {key: value for key, value in os.environ.items() if not key.startswith("KEYCHORD_")}
        self.env.update(PATH=str(self.mock_dir) + os.pathsep + os.environ["PATH"],
                        BUILD_CHECK_LOG=str(self.log), BUILD_CHECK_BIN=str(self.bin),
                        BUILD_CHECK_RUNNING=str(self.running))

    def run_build(self, *args, **env):
        result = subprocess.run([str(self.root / "build-app.sh"), *args],
                                cwd=self.temp.name, env=self.env | env,
                                capture_output=True, text=True, timeout=30)
        calls = [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []
        return result, calls

    def test_default_ad_hoc_build_resets_only_accessibility_and_opens_verified_app(self):
        result, calls = self.run_build()
        self.assertEqual(result.returncode, 0, result.stderr)
        app = self.root / "build/KeyChord.app"
        self.assertEqual((app / "Contents/MacOS/KeyChord").read_text(), "new executable")
        self.assertEqual([call for call in calls if call[0] == "tccutil"],
                         [["tccutil", "reset", "Accessibility", "dev.keychord.KeyChord"]])
        verify = ["codesign", "--verify", "--deep", "--strict", str(app)]
        reset = ["tccutil", "reset", "Accessibility", "dev.keychord.KeyChord"]
        self.assertLess(calls.index(verify), calls.index(reset))
        self.assertEqual(calls[-1], ["open", str(app)])

    def test_root_entry_point_forwards_configuration(self):
        result, calls = self.run_build("debug")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls[0], ["swift", "build", "-c", "debug", "--product", "KeyChord"])

    def test_signed_build_preserves_grants_by_default(self):
        result, calls = self.run_build(KEYCHORD_SIGN_IDENTITY="KeyChord Test Identity")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any(call[0] == "tccutil" for call in calls))
        sign = next(call for call in calls if call[0] == "codesign" and "--sign" in call)
        self.assertEqual(sign[sign.index("--sign") + 1], "KeyChord Test Identity")

    def test_explicit_reset_applies_to_certificate_signed_builds(self):
        result, calls = self.run_build(KEYCHORD_SIGN_IDENTITY="KeyChord Test Identity", KEYCHORD_RESET_TCC="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(any(call[0] == "tccutil" for call in calls))

    def test_permission_preservation_and_packaging_overrides(self):
        result, calls = self.run_build(KEYCHORD_RESET_TCC="0", KEYCHORD_LAUNCH="0")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any(call[0] in ("tccutil", "open") for call in calls))

    def test_failed_reset_is_reported_and_does_not_launch(self):
        result, calls = self.run_build(BUILD_CHECK_FAIL="tccutil")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Could not reset Accessibility", result.stderr)
        self.assertNotIn("Reset Accessibility for", result.stdout)
        self.assertFalse(any(call[0] == "open" for call in calls))

    def test_build_signing_or_verification_failure_cannot_reset_or_launch(self):
        for failure in ("swift", "codesign", "verify"):
            with self.subTest(failure=failure):
                self.log.unlink(missing_ok=True)
                result, calls = self.run_build(BUILD_CHECK_FAIL=failure)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(any(call[0] in ("tccutil", "open") for call in calls))
                if failure == "swift":
                    self.assertFalse(any(call[0] == "pkill" for call in calls))

    def test_running_app_quits_before_replacement_and_reset(self):
        self.running.touch()
        result, calls = self.run_build()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.running.exists())
        self.assertLess(calls.index(["pkill", "-x", "KeyChord"]),
                        next(index for index, call in enumerate(calls) if call[0] == "codesign"))

    def test_app_that_does_not_quit_is_not_replaced(self):
        self.running.touch()
        result, calls = self.run_build(BUILD_CHECK_STUCK="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("KeyChord did not quit", result.stderr)
        self.assertFalse((self.root / "build/KeyChord.app").exists())
        self.assertFalse(any(call[0] in ("codesign", "tccutil", "open") for call in calls))

    def test_invalid_options_fail_before_building(self):
        for env in ({"KEYCHORD_RESET_TCC": "typo"}, {"KEYCHORD_LAUNCH": "typo"}):
            with self.subTest(env=env):
                result, calls = self.run_build(**env)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(calls, [])


if __name__ == "__main__":
    unittest.main()
